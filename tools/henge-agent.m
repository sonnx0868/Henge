// Runs inside macOS on a Henge virtual Mac, as a LaunchAgent. It keeps the clipboard in step with the device,
// and keeps the shared folder mounted. It talks to host/share.c at 10.0.2.4, which only exists inside Henge.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include "scroll_pixels.h"
#include "scroll_wheel.h"

#define HOST "10.0.2.4"
static int send_all(int fd, const void *p, size_t n);
static NSData *request(NSString *method, NSString *path, NSData *body, int *status, unsigned long *seq);

static NSLock *scrollLock;
static double pendingScrollX, pendingScrollY, pendingScrollScale = 0.3;
static CFAbsoluteTime pendingSince, pendingUpdated;
static BOOL scrollScheduled;
static unsigned long scrollGeneration;
static CFAbsoluteTime lastScrollTime;
static CFAbsoluteTime lastMotionTime;
static dispatch_queue_t scrollDeliveryQueue;
static HvScrollPixelMapper pixelMapper;
static double reportRawX, reportRawY, reportScale = 0.3, reportDelay;
static long long reportX, reportY, reportPointX, reportPointY;
static unsigned reportFrames, reportDropped;
static CFAbsoluteTime reportStarted;
static char reportKind = 'P';
static HvScrollWheel wheelMotion;
static double wheelReceivedX, wheelReceivedY, wheelScale = 0.3;
static BOOL wheelScheduled;
static CFAbsoluteTime lastWheelPost;

static void postPixels(int x, int y, int phase) {
    /* Pixel units bypass the mouse driver's wheel acceleration. */
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, y, x);
    if (!event) return;
    CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, phase);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventMomentumPhase, 0);
    if (x || y) {
        reportPointX += CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        reportPointY += CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    }
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void reportScroll(CFAbsoluteTime now, BOOL force) {
    if (!reportStarted) reportStarted = now;
    if ((!force && now - reportStarted < 1) || (!reportFrames && !reportDropped)) return;
    NSString *text = [NSString stringWithFormat:@"%.6f %.3f %.3f %lld %lld %lld %lld %u %.3f %u %c",
                      reportScale, reportRawX, reportRawY, reportX, reportY, reportPointX, reportPointY,
                      reportFrames, reportDelay, reportDropped, reportKind];
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding];
    reportRawX = reportRawY = reportDelay = 0;
    reportX = reportY = reportPointX = reportPointY = 0;
    reportFrames = reportDropped = 0;
    reportStarted = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        request(@"POST", @"/.henge/scroll-report", body, &status, NULL);
    });
}

static void selectScrollReport(char kind, double scale, CFAbsoluteTime now) {
    if ((reportFrames || reportDropped) && (reportKind != kind || reportScale != scale)) reportScroll(now, YES);
    reportKind = kind;
    reportScale = scale;
}

static void deliverWheel(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [scrollLock lock];
    HvScrollWheelFrame frame = hv_scroll_wheel_take(&wheelMotion, now);
    double receivedX = wheelReceivedX, receivedY = wheelReceivedY, gain = wheelScale;
    double delay = MAX(0, now - wheelMotion.last_input) * 1000;
    wheelReceivedX = wheelReceivedY = 0;
    BOOL more = hv_scroll_wheel_pending(&wheelMotion);
    wheelScheduled = more;
    [scrollLock unlock];
    selectScrollReport('W', gain, now);
    reportRawX += receivedX;
    reportRawY += receivedY;
    if (frame.x || frame.y) {
        reportFrames++;
        reportDelay = MAX(reportDelay, delay);
        reportX += frame.x;
        reportY += frame.y;
        postPixels(frame.x, frame.y, now - lastWheelPost > 0.12 ? 1 : 2);
        lastWheelPost = now;
        unsigned long generation = ++scrollGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), scrollDeliveryQueue, ^{
            if (scrollGeneration == generation) {
                postPixels(0, 0, 4);
                reportScroll(CFAbsoluteTimeGetCurrent(), YES);
            }
        });
    }
    reportScroll(now, NO);
    if (more) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 60), scrollDeliveryQueue, ^{ deliverWheel(); });
}

static void queueWheel(double x, double y, double scale) {
    if (!x && !y) return;
    [scrollLock lock];
    hv_scroll_wheel_append(&wheelMotion, x, y, CFAbsoluteTimeGetCurrent());
    wheelReceivedX += x;
    wheelReceivedY += y;
    wheelScale = scale;
    BOOL schedule = !wheelScheduled && hv_scroll_wheel_pending(&wheelMotion);
    if (schedule) wheelScheduled = YES;
    [scrollLock unlock];
    if (schedule) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 60), scrollDeliveryQueue, ^{ deliverWheel(); });
}

static void queueMotion(double x, double y, double scale) {
    if (!x && !y) return; /* stream heartbeat */
    [scrollLock lock];
    pendingScrollX = MAX(-64, MIN(64, pendingScrollX + x));
    pendingScrollY = MAX(-64, MIN(64, pendingScrollY + y));
    pendingScrollScale = scale;
    pendingUpdated = CFAbsoluteTimeGetCurrent();
    BOOL schedule = !scrollScheduled;
    if (schedule) pendingSince = pendingUpdated;
    scrollScheduled = YES;
    [scrollLock unlock];
    if (!schedule) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 60), scrollDeliveryQueue, ^{
        [scrollLock lock];
        double rawX = pendingScrollX, rawY = pendingScrollY, gain = pendingScrollScale;
        CFAbsoluteTime first = pendingSince, latest = pendingUpdated;
        pendingScrollX = pendingScrollY = 0;
        scrollScheduled = NO;
        [scrollLock unlock];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        selectScrollReport('P', gain, now);
        if (now - latest > 0.1) {
            reportDropped++;
            pixelMapper = (HvScrollPixelMapper){0};
            lastMotionTime = 0;
            reportScroll(now, YES);
            return;
        }
        BOOL began = now - lastScrollTime > 0.12;
        if (now - lastMotionTime > 0.12) pixelMapper = (HvScrollPixelMapper){0};
        lastMotionTime = now;
        reportRawX += rawX;
        reportRawY += rawY;
        reportFrames++;
        reportDelay = MAX(reportDelay, (now - first) * 1000);
        HvScrollPixelFrame frame = hv_scroll_pixels_apply(&pixelMapper, rawX, rawY, gain);
        if (!frame.x && !frame.y) { reportScroll(now, NO); return; }
        reportX += frame.x;
        reportY += frame.y;
        postPixels(frame.x, frame.y, began ? 1 : 2);
        lastScrollTime = now;
        reportScroll(now, NO);
        unsigned long generation = ++scrollGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), scrollDeliveryQueue, ^{
            if (scrollGeneration == generation) {
                postPixels(0, 0, 4);
                reportScroll(CFAbsoluteTimeGetCurrent(), YES);
            }
        });
    });
}

static void followScroll(void) {
    for (;;) {
        @autoreleasepool {
            if (!AXIsProcessTrusted()) { sleep(1); continue; }
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) { sleep(1); continue; }
            struct timeval timeout = {.tv_sec = 3};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
            struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(80)};
            inet_pton(AF_INET, HOST, &addr.sin_addr);
            static const char head[] = "GET /.henge/scroll-v2?wheel=1 HTTP/1.1\r\nHost: " HOST "\r\nConnection: close\r\n\r\n";
            if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0 && send_all(fd, head, sizeof head - 1) == 0) {
                NSMutableData *pending = [NSMutableData data];
                BOOL headers = YES;
                CFAbsoluteTime checked = CFAbsoluteTimeGetCurrent();
                char bytes[4096];
                for (;;) {
                    ssize_t n = recv(fd, bytes, sizeof bytes, 0);
                    if (n <= 0) break;
                    if (CFAbsoluteTimeGetCurrent() - checked >= 1) {
                        checked = CFAbsoluteTimeGetCurrent();
                        if (!AXIsProcessTrusted()) break;
                    }
                    [pending appendBytes:bytes length:(NSUInteger)n];
                    if (pending.length > 32768) break;
                    if (headers) {
                        NSRange end = [pending rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, pending.length)];
                        if (end.location == NSNotFound) continue;
                        if (pending.length < 12 || memcmp(pending.bytes, "HTTP/1.1 200", 12)) break;
                        [pending replaceBytesInRange:NSMakeRange(0, NSMaxRange(end)) withBytes:NULL length:0];
                        headers = NO;
                    }
                    for (;;) {
                        NSRange end = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, pending.length)];
                        if (end.location == NSNotFound) break;
                        NSString *line = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
                        HvScrollLine motion;
                        if (line && hv_scroll_parse_line(line.UTF8String, &motion)) {
                            if (motion.kind == 'W') queueWheel(motion.x, motion.y, motion.scale); // gain already applied by the host
                            else queueMotion(motion.x, motion.y, motion.scale);
                        }
                        [pending replaceBytesInRange:NSMakeRange(0, NSMaxRange(end)) withBytes:NULL length:0];
                    }
                }
            }
            close(fd);
            [scrollLock lock];
            pendingScrollX = pendingScrollY = 0;
            wheelMotion = (HvScrollWheel){0};
            wheelReceivedX = wheelReceivedY = 0;
            [scrollLock unlock];
            sleep(1);
        }
    }
}

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

// One request on its own connection. A plain socket: the server is ours, and URLSession refuses plain HTTP.
static NSData *request(NSString *method, NSString *path, NSData *body, int *status, unsigned long *seq) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval timeout = {.tv_sec = 40};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(80)};
    inet_pton(AF_INET, HOST, &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return nil;
    }
    NSString *head = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: " HOST "\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", method, path,
                                                (unsigned long)body.length];
    const char *text = head.UTF8String;
    if (send_all(fd, text, strlen(text)) != 0 || (body.length && send_all(fd, body.bytes, body.length) != 0)) {
        close(fd);
        return nil;
    }
    NSMutableData *all = [NSMutableData data];
    char piece[16384];
    for (;;) {
        ssize_t got = recv(fd, piece, sizeof piece, 0);
        if (got <= 0) break;
        [all appendBytes:piece length:(NSUInteger)got];
    }
    close(fd);
    NSRange end = [all rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, all.length)];
    if (end.location == NSNotFound) return nil;
    NSString *headers = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    if (sscanf(headers.UTF8String, "HTTP/1.1 %d", status) != 1) return nil;
    NSRange found = [headers rangeOfString:@"X-Henge-Seq: "];
    if (found.location != NSNotFound && seq) *seq = strtoul(headers.UTF8String + NSMaxRange(found), NULL, 10);
    NSUInteger start = NSMaxRange(end);
    return [all subdataWithRange:NSMakeRange(start, all.length - start)];
}

static NSInteger lastChange;

// The device's clipboard, as it changes. The server holds each request until there is something new.
static void followDevice(void) {
    unsigned long seq = 0;
    for (BOOL first = YES;; first = NO) {
        int status = 0;
        unsigned long now = seq;
        NSData *body = request(@"GET", [NSString stringWithFormat:@"/.henge/clipboard?since=%lu", first ? ULONG_MAX >> 1 : seq], nil, &status, &now);
        if (!body) {
            sleep(5);
            continue;
        }
        BOOL news = !first && status == 200 && now != seq;
        seq = now; // what the device had before this helper started isn't news
        if (!news) continue;
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!text) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            [board clearContents];
            [board setString:text forType:NSPasteboardTypeString];
            lastChange = board.changeCount;
        });
    }
}

// The Mac's clipboard goes to the device, unless the app that copied it marked it as secret.
static void checkClipboard(void) {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (board.changeCount == lastChange) return;
    lastChange = board.changeCount;
    if ([board.types containsObject:@"org.nspasteboard.ConcealedType"]) return;
    NSString *text = [board stringForType:NSPasteboardTypeString];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        request(@"PUT", @"/.henge/clipboard", data, &status, NULL);
    });
}

static NSString *mountPoint(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Henge"]; }

// Can the share server still be reached? Its install script is a tiny page it always serves.
static BOOL serverReachable(void) {
    int status = 0;
    NSData *body = request(@"GET", @"/.henge/install", nil, &status, NULL);
    return body != nil && status == 200;
}

static void unmount(NSString *point) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/umount"];
    task.arguments = @[ point ];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launchAndReturnError:NULL];
    [task waitUntilExit];
    if (task.terminationStatus != 0) { // a busy or wedged mount needs the stronger form
        NSTask *force = [NSTask new];
        force.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/diskutil"];
        force.arguments = @[ @"unmount", @"force", point ];
        force.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        force.standardError = NSFileHandle.fileHandleWithNullDevice;
        [force launchAndReturnError:NULL];
        [force waitUntilExit];
    }
}

// The shared folder, at ~/Henge. mount_webdav needs an empty folder it owns, and is a no-op failure if it is mounted.
static void keepMounted(void) {
    NSString *point = mountPoint();
    [NSFileManager.defaultManager createDirectoryAtPath:point withIntermediateDirectories:YES attributes:nil error:NULL];
    struct stat folder, parent;
    if (stat(point.fileSystemRepresentation, &folder) != 0 || stat(NSHomeDirectory().fileSystemRepresentation, &parent) != 0) return;
    if (folder.st_dev != parent.st_dev) { // something's volume is mounted there
        // The device side of the share restarts (app resumed, root changed): the mount
        // can outlive the server it was made against and serve a dead socket forever. If the
        // server no longer answers, drop the mount; the code below remounts it, and the next
        // 30 s pass retries if the server is still coming back.
        if (serverReachable()) return;
        unmount(point);
        struct stat after;
        if (stat(point.fileSystemRepresentation, &after) != 0 || after.st_dev != parent.st_dev) return; // still mounted: leave it
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/mount_webdav"];
    task.arguments = @[ @"-S", @"-v", @"Henge", @"http://" HOST "/", point ];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launchAndReturnError:NULL];
}

int main(void) {
    @autoreleasepool {
        scrollLock = [NSLock new];
        scrollDeliveryQueue = dispatch_queue_create("com.henge.scroll-delivery",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ followScroll(); });
        lastChange = NSPasteboard.generalPasteboard.changeCount;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ followDevice(); });
        keepMounted();
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; checkClipboard(); }];
        [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) { (void)timer; keepMounted(); }];
        [NSRunLoop.mainRunLoop run];
    }
    return 0;
}
