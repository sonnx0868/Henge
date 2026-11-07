#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *stopPacket(int command) {
    return [NSString stringWithFormat:@"T05thread:1;20:0010000001000000;10:%@;00:0000000000000000;01:0000004000000000;",
            command ? @"0100000000000000" : @"0000000000000000"];
}

static BOOL runScenario(NSString *source, NSString *response, BOOL succeeds) {
    JSContext *context = [JSContext new];
    __block double address = -1, length = -1;
    __block int preparations = 0, stops = 0;
    __block BOOL released = NO;
    __block NSString *returned = nil;
    context[@"get_pid"] = ^int { return 513; };
    context[@"log"] = ^(JSValue *value) { (void)value; };
    context[@"prepare_memory_region"] = ^NSString *(double a, double n) {
        preparations++;
        address = a;
        length = n;
        return response;
    };
    context[@"send_command"] = ^NSString *(NSString *command) {
        if ([command isEqualToString:@"c"]) {
            if (++stops > 3) { fprintf(stderr, "JIT script did not detach\n"); exit(1); }
            return stopPacket(stops == 1 ? 1 : 0);
        }
        if ([command isEqualToString:@"_M40000000,rx"]) return @"7000000000";
        if ([command isEqualToString:@"_m7000000000"]) released = YES;
        if ([command hasPrefix:@"m"]) return @"a0013ed4"; /* brk #0xf00d */
        if ([command hasPrefix:@"P0="]) returned = command;
        return @"OK";
    };
    [context evaluateScript:source];
    NSString *want = succeeds ? @"P0=0000000070000000;thread:1;" : @"P0=0000000000000000;thread:1;";
    BOOL ok = !context.exception && preparations == 1 && address == 481036337152.0 && length == 1073741824.0 &&
              [returned isEqualToString:want] && released == !succeeds && stops == 2;
    printf("JIT script %s: %s (address %.0f, length %.0f, prepared %d)\n",
           succeeds ? "high-address success" : "preparation rejection", ok ? "ok" : "FAIL", address, length, preparations);
    if (!ok) fprintf(stderr, "exception=%s returned=%s released=%d\n", context.exception.toString.UTF8String,
                     returned.UTF8String, released);
    return ok;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        JSContext *probe = [JSContext new];
        __block double a = -1, n = -1;
        probe[@"prepare_memory_region"] = ^NSString *(double address, double length) { a = address; n = length; return @"OK"; };
        [probe evaluateScript:@"prepare_memory_region(0x7000000000n, 1073741824n)"];
        printf("JavaScriptCore BigInt -> native Double observation: address %.0f length %.0f exception %s\n", a, n,
               probe.exception ? probe.exception.toString.UTF8String : "none");
        NSString *path = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"ios/Henge/Resources/henge-jit.js";
        NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (!source) return 1;
        return runScenario(source, @"OK", YES) && runScenario(source, @"E42", NO) && runScenario(source, @"", NO) ? 0 : 1;
    }
}
