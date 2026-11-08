#include "share.h"
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static int line(int fd, char *buf, size_t cap) {
    size_t at = 0;
    while (at + 1 < cap) {
        char c;
        if (recv(fd, &c, 1, 0) != 1) return -1;
        buf[at++] = c;
        if (c == '\n') { buf[at] = 0; return 0; }
    }
    return -1;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    char folder[] = "/tmp/henge-scroll-XXXXXX", path[108];
    if (!mkdtemp(folder)) return 1;
    snprintf(path, sizeof path, "%s/s.sock", folder);
    if (hv_share_start(folder, path, NULL) != 0 || hv_share_scroll_ready() || hv_share_scroll_motion(1, 1, 0.3)) return 1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct timeval timeout = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 1;
    const char request[] = "GET /.henge/scroll-v2 HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n";
    if (send(fd, request, sizeof request - 1, 0) != sizeof request - 1) return 1;
    char buf[256];
    if (line(fd, buf, sizeof buf) || !strstr(buf, "200 OK")) return 1;
    do { if (line(fd, buf, sizeof buf)) return 1; } while (strcmp(buf, "\r\n"));
    for (int i = 0; i < 100 && !hv_share_scroll_ready(); i++) usleep(10000);
    if (hv_share_scroll_wheel_ready() || hv_share_scroll_wheel(0, 32, 1.5)) return 1; // old helpers cannot consume typed wheel pixels
    if (!hv_share_scroll_motion(41, -9, 0.1) || line(fd, buf, sizeof buf)) return 1;
    double x, y, scale;
    if (sscanf(buf, "%lf %lf %lf", &x, &y, &scale) != 3 || x != 41 || y != -9 || fabs(scale - 0.1) > 0.000001) return 1;
    if (!hv_share_scroll_motion(400, -400, 1.5) || line(fd, buf, sizeof buf)) return 1;
    if (sscanf(buf, "%lf %lf %lf", &x, &y, &scale) != 3 || x != 64 || y != -64 || scale != 1.5) return 1;
    shutdown(fd, SHUT_RDWR);
    close(fd);
    for (int i = 0; i < 400 && hv_share_scroll_ready(); i++) usleep(10000);
    int ready = hv_share_scroll_ready();
    if (ready || hv_share_scroll_motion(1, 1, 0.3)) return 1;
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 1;
    const char typed_request[] = "GET /.henge/scroll-v2?wheel=1 HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n";
    if (send(fd, typed_request, sizeof typed_request - 1, 0) != sizeof typed_request - 1) return 1;
    if (line(fd, buf, sizeof buf) || !strstr(buf, "200 OK")) return 1;
    do { if (line(fd, buf, sizeof buf)) return 1; } while (strcmp(buf, "\r\n"));
    for (int i = 0; i < 100 && !hv_share_scroll_wheel_ready(); i++) usleep(10000);
    if (!hv_share_scroll_wheel_ready()) return 1;
    for (int mode = 0; mode < 3; mode++) {
        double total = 0;
        if (mode == 1) for (int i = 0; i < 5; i++) { if (!hv_share_scroll_wheel(0, 32, 1.5)) return 1; }
        if (mode == 2 && !hv_share_scroll_wheel(0, 160, 1.5)) return 1;
        for (int i = 0; i < (mode == 0 ? 5 : 20) && total < 800; i++) {
            if (mode == 0 && !hv_share_scroll_wheel(0, 32, 1.5)) return 1;
            if (line(fd, buf, sizeof buf)) return 1;
            char kind;
            if (sscanf(buf, "%c %lf %lf %lf", &kind, &x, &y, &scale) != 4) return 1;
            if (kind == 'W') { if (x != 0 || scale != 1.5) return 1; total += y; }
        }
        if (total != 800) return 1; // isolated, server-coalesced and app-coalesced all equal
    }
    if (!hv_share_scroll_motion(0, 7, 0.1) || !hv_share_scroll_wheel(0, 32, 1.5)) return 1;
    int pad_seen = 0, wheel_seen = 0;
    for (int i = 0; i < 4 && (!pad_seen || !wheel_seen); i++) {
        if (line(fd, buf, sizeof buf)) return 1;
        char kind;
        if (sscanf(buf, "%c %lf %lf %lf", &kind, &x, &y, &scale) != 4) return 1;
        if (kind == 'P' && y == 7 && scale == 0.1) pad_seen = 1;
        if (kind == 'W' && y == 160 && scale == 1.5) wheel_seen = 1;
    }
    if (!pad_seen || !wheel_seen) return 1;
    shutdown(fd, SHUT_RDWR);
    close(fd);
    for (int i = 0; i < 400 && hv_share_scroll_ready(); i++) usleep(10000);
    if (hv_share_scroll_wheel_ready()) return 1;
    unlink(path);
    rmdir(folder);
    puts("scroll bridge v3: isolated/fast/coalesced wheel distance equal at 5x; wheel/pad gains stay independent");
    puts("scroll bridge v2: raw motion and gain delivery, bounded queue and disconnect detection passed");
    return 0;
}
