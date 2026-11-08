#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <pthread/qos.h>
#include <stdlib.h>
#include <string.h>
#include "image_service.h"
#include "image_ops.h"

static CGContextRef bitmap_context(size_t w, size_t h) {
    if (!hv_image_dimensions(w, h)) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    return ctx;
}
static NSData *png_image(CGImageRef image) {
    if (!image) return nil;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    if (!dest) return nil;
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? data : nil;
}
static NSDictionary *analysis(CGContextRef ctx, HvImageAlpha a) {
    unsigned rgb[3];
    int solid = hv_image_background(CGBitmapContextGetData(ctx), CGBitmapContextGetWidth(ctx),
        CGBitmapContextGetHeight(ctx), CGBitmapContextGetBytesPerRow(ctx), a, rgb);
    return @{ @"color": [NSString stringWithFormat:@"#%02x%02x%02x", rgb[0], rgb[1], rgb[2]], @"hasSolidBg": solid ? @YES : @NO };
}
int hv_native_image_process(const uint8_t *input, size_t bytes, int extension, int pad, int analyze_only,
                            uint8_t **output, size_t *output_bytes) {
    *output = NULL; *output_bytes = 0;
    if (!input || !bytes || bytes > HV_IMAGE_INPUT_MAX) return 413;
    @autoreleasepool {
        /* This is a sharing connection's own thread, never a guest CPU or UI thread. */
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        NSData *data = [NSData dataWithBytesNoCopy:(void *)input length:bytes freeWhenDone:NO];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) return 415;
        NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        size_t raw_w = [props[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
        size_t raw_h = [props[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
        unsigned orientation = [props[(__bridge NSString *)kCGImagePropertyOrientation] unsignedIntValue];
        size_t w = orientation >= 5 && orientation <= 8 ? raw_h : raw_w;
        size_t h = orientation >= 5 && orientation <= 8 ? raw_w : raw_h;
        if (!hv_image_dimensions(w, h)) { CFRelease(source); return 413; }
#if TARGET_OS_IPHONE
        /* Keep decoder/context/PNG scratch out of the app's remaining jetsam headroom. */
        if (os_proc_available_memory() < w * h * 24ull + bytes * 2ull + (64ull << 20)) { CFRelease(source); return 429; }
#endif
        BOOL is_png = input[0] == 137 && bytes >= 8 && !memcmp(input, "\x89PNG\r\n\x1a\n", 8);
        size_t target_w = w, target_h = h;
        if (!analyze_only && extension && hv_image_fixed(w, h) != 2 && (w > 3000 || h > 3000)) {
            double ratio = 3000.0 / (w > h ? w : h);
            target_w = (size_t)(w * ratio + 0.5); target_h = (size_t)(h * ratio + 0.5);
        }
        CGImageRef decoded;
        if (orientation > 1) {
            NSDictionary *opts = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(w > h ? w : h),
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES};
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)opts);
        } else {
            decoded = CGImageSourceCreateImageAtIndex(source, 0,
                (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES});
        }
        CFRelease(source);
        if (!decoded) return 422;
        CGContextRef base = bitmap_context(target_w, target_h);
        if (!base) { CGImageRelease(decoded); return 500; }
        CGContextDrawImage(base, CGRectMake(0, 0, target_w, target_h), decoded);
        CGImageRelease(decoded);
        w = target_w; h = target_h;
        HvImageAlpha a = hv_image_alpha(CGBitmapContextGetData(base), w, h, CGBitmapContextGetBytesPerRow(base));
        HvImagePlan plan = hv_image_plan(w, h, a, pad);
        BOOL unchanged = plan.crop_w == w && plan.crop_h == h && !plan.padding && plan.width == w && plan.height == h;
        BOOL normalized = w != (orientation >= 5 && orientation <= 8 ? raw_h : raw_w)
            || h != (orientation >= 5 && orientation <= 8 ? raw_w : raw_h);
        BOOL passthrough = !analyze_only && unchanged && !normalized && is_png && orientation <= 1;
        NSData *original = nil, *result_png = nil;
        NSMutableDictionary *meta = [@{@"protocol": @1, @"backend": @"native-imageio",
            @"width": @(analyze_only ? w : plan.width), @"height": @(analyze_only ? h : plan.height),
            @"passthrough": @(passthrough)} mutableCopy];
        int status = 200;
        if (!analyze_only && (plan.fixed || extension) && (normalized || !is_png || orientation > 1)) {
            CGImageRef image = CGBitmapContextCreateImage(base);
            original = png_image(image); if (image) CGImageRelease(image);
            if (!original) status = 500;
        }
        if (!analyze_only && plan.fixed) {
            size_t left = a.present ? a.left : 0, top = a.present ? a.top : 0;
            meta[@"fixedCanvas"] = @{@"canvasWidth": @(w), @"canvasHeight": @(h), @"lockCanvas": @YES,
                @"sourceKind": plan.fixed == 1 ? @"fixed-import-1417x2362" : @"order-canvas-4500x5100",
                @"bounds": @{@"left": @(left), @"top": @(top), @"right": @(left + plan.crop_w - 1),
                    @"bottom": @(top + plan.crop_h - 1), @"width": @(plan.crop_w), @"height": @(plan.crop_h)}};
        }
        CGContextRef final = base;
        if (!analyze_only && !unchanged && status == 200) {
            size_t pw = plan.crop_w + plan.padding * 2, ph = plan.crop_h + plan.padding * 2;
            CGContextRef cropped_ctx = bitmap_context(pw, ph);
            CGImageRef base_image = CGBitmapContextCreateImage(base);
            CGRect bounds = CGRectMake(a.present ? a.left : 0, a.present ? a.top : 0, plan.crop_w, plan.crop_h);
            CGImageRef cropped = base_image ? CGImageCreateWithImageInRect(base_image, bounds) : NULL;
            if (base_image) CGImageRelease(base_image);
            if (!cropped_ctx || !cropped) status = 500;
            else CGContextDrawImage(cropped_ctx, CGRectMake(plan.padding, plan.padding, plan.crop_w, plan.crop_h), cropped);
            if (cropped) CGImageRelease(cropped);
            if (status == 200) {
                if (pw == plan.width && ph == plan.height) final = cropped_ctx;
                else {
                    final = bitmap_context(plan.width, plan.height);
                    CGImageRef image = CGBitmapContextCreateImage(cropped_ctx);
                    if (!final || !image) status = 500;
                    else { CGContextSetInterpolationQuality(final, kCGInterpolationHigh); CGContextDrawImage(final, CGRectMake(0, 0, plan.width, plan.height), image); }
                    if (image) CGImageRelease(image);
                    CGContextRelease(cropped_ctx);
                }
            } else if (cropped_ctx) CGContextRelease(cropped_ctx);
        }
        if (status == 200) {
            HvImageAlpha fa = final == base ? a : hv_image_alpha(CGBitmapContextGetData(final), plan.width, plan.height, CGBitmapContextGetBytesPerRow(final));
            meta[@"analysis"] = analysis(final, fa);
            if (!analyze_only && !passthrough) {
                CGImageRef image = CGBitmapContextCreateImage(final);
                result_png = png_image(image); if (image) CGImageRelease(image);
                if (!result_png) status = 500;
            }
        }
        if (final && final != base) CGContextRelease(final);
        CGContextRelease(base);
        if (status != 200) return status;
        meta[@"imageBytes"] = @(result_png.length);
        meta[@"originalBytes"] = @(original.length);
        meta[@"milliseconds"] = @((CFAbsoluteTimeGetCurrent() - started) * 1000);
        NSData *json = [NSJSONSerialization dataWithJSONObject:meta options:0 error:NULL];
        if (!json || json.length > 65536 || result_png.length + original.length > HV_IMAGE_OUTPUT_MAX - json.length - 4) return 413;
        size_t total = 4 + json.length + result_png.length + original.length;
        uint8_t *out = malloc(total);
        if (!out) return 500;
        uint32_t n = (uint32_t)json.length;
        out[0] = n >> 24; out[1] = n >> 16; out[2] = n >> 8; out[3] = n;
        memcpy(out + 4, json.bytes, json.length);
        if (result_png.length) memcpy(out + 4 + json.length, result_png.bytes, result_png.length);
        if (original.length) memcpy(out + 4 + json.length + result_png.length, original.bytes, original.length);
        *output = out; *output_bytes = total;
        return 200;
    }
}
