#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <assert.h>
#include "image_ops.h"
#include "image_service.h"

static NSData *fixture(size_t w, size_t h, size_t x0, size_t y0, size_t rw, size_t rh) {
    uint8_t *bytes = calloc(w * h, 4);
    assert(bytes);
    for (size_t y = y0; y < y0 + rh; y++) for (size_t x = x0; x < x0 + rw; x++) {
        size_t i = (y * w + x) * 4;
        bytes[i] = 18; bytes[i + 1] = 171; bytes[i + 2] = 52; bytes[i + 3] = 255;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(bytes, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    assert(ctx);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    assert(dest);
    CGImageDestinationAddImage(dest, image, NULL);
    assert(CGImageDestinationFinalize(dest));
    CFRelease(dest); CGImageRelease(image); CGContextRelease(ctx); CGColorSpaceRelease(space); free(bytes);
    return data;
}
static NSDictionary *prepare(NSData *data, int extension, int pad, int analyze, NSData **image_data) {
    uint8_t *out = NULL; size_t bytes = 0;
    int status = hv_native_image_process(data.bytes, data.length, extension, pad, analyze, &out, &bytes);
    assert(status == 200 && bytes >= 4);
    size_t n = (size_t)out[0] << 24 | (size_t)out[1] << 16 | (size_t)out[2] << 8 | out[3];
    assert(n && n < bytes);
    NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:out + 4 length:n] options:0 error:NULL];
    assert(meta && [meta[@"protocol"] intValue] == 1);
    size_t image_bytes = [meta[@"imageBytes"] unsignedLongLongValue], original = [meta[@"originalBytes"] unsignedLongLongValue];
    assert(bytes == 4 + n + image_bytes + original);
    if (image_data) *image_data = [NSData dataWithBytes:out + 4 + n length:image_bytes];
    free(out);
    return meta;
}
int main(void) {
    @autoreleasepool {
        assert(hv_image_dimensions(4500, 5100));
        assert(!hv_image_dimensions(6000, 5000) && !hv_image_dimensions(SIZE_MAX, 2) && !hv_image_dimensions(10, 0));
        uint8_t *out; size_t bytes;
        assert(hv_native_image_process((const uint8_t *)"x", HV_IMAGE_INPUT_MAX + 1ull, 0, 0, 0, &out, &bytes) == 413);
        assert(hv_native_image_process((const uint8_t *)"broken image", 12, 0, 0, 0, &out, &bytes) != 200);
        NSData *opaque = fixture(1600, 1000, 0, 0, 1600, 1000);
        NSDictionary *meta = prepare(opaque, 0, 0, 0, NULL);
        assert([meta[@"passthrough"] boolValue] && [meta[@"imageBytes"] intValue] == 0);
        assert([meta[@"analysis"][@"hasSolidBg"] boolValue]);
        assert([meta[@"analysis"][@"color"] isEqual:@"#12ab34"]);
        meta = prepare(opaque, 0, 1, 0, NULL);
        assert([meta[@"width"] intValue] == 1640 && [meta[@"height"] intValue] == 1040);
        NSData *fixed = fixture(1417, 2362, 200, 300, 100, 80), *image;
        meta = prepare(fixed, 1, 1, 0, &image);
        assert([meta[@"width"] intValue] == 100 && [meta[@"height"] intValue] == 80);
        assert([meta[@"fixedCanvas"][@"bounds"][@"top"] intValue] == 300);
        assert([meta[@"fixedCanvas"][@"bounds"][@"left"] intValue] == 200);
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)image, NULL);
        CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        assert(decoded && CGImageGetWidth(decoded) == 100 && CGImageGetHeight(decoded) == 80);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        uint8_t pixel[4] = {0};
        CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), decoded);
        assert(pixel[0] == 18 && pixel[1] == 171 && pixel[2] == 52 && pixel[3] == 255);
        CGContextRelease(ctx); CGColorSpaceRelease(space); CGImageRelease(decoded); CFRelease(source);
        NSData *large = fixture(3600, 2400, 0, 0, 3600, 2400);
        meta = prepare(large, 1, 1, 0, NULL);
        assert([meta[@"width"] intValue] == 3040 && [meta[@"height"] intValue] == 2040 && [meta[@"originalBytes"] intValue] > 0);
        meta = prepare(large, 0, 1, 0, NULL);
        assert([meta[@"width"] intValue] == 3500 && [meta[@"height"] intValue] == (int)(2440.0 * 3500 / 3640 + 0.5));
        @autoreleasepool {
            NSData *production = fixture(4500, 5100, 0, 0, 4500, 5100);
            meta = prepare(production, 1, 1, 0, NULL);
            assert([meta[@"width"] intValue] == 4500 && [meta[@"height"] intValue] == 5100 && [meta[@"passthrough"] boolValue]);
            printf("Native 4500x5100 prepare: %.1f ms\n", [meta[@"milliseconds"] doubleValue]);
        }
        meta = prepare(opaque, 0, 0, 1, NULL);
        assert([meta[@"imageBytes"] intValue] == 0 && [meta[@"analysis"][@"hasSolidBg"] boolValue]);
        puts("native image: RGBA color, asymmetric crop, fixed frames, padding, extension/binary limits, passthrough, analysis and budgets passed");
    }
    return 0;
}
