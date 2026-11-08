#ifndef HV_IMAGE_OPS_H
#define HV_IMAGE_OPS_H
#include <stddef.h>
#include <stdint.h>
#define HV_IMAGE_INPUT_MAX (32u * 1024u * 1024u)
#define HV_IMAGE_PIXELS_MAX 24000000u
#define HV_IMAGE_OUTPUT_MAX (128u * 1024u * 1024u)
typedef struct { size_t left, top, right, bottom, content, opaque; int present; } HvImageAlpha;
typedef struct { size_t width, height, crop_w, crop_h, padding; int fixed; } HvImagePlan;
static inline int hv_image_dimensions(size_t w, size_t h) {
    return w && h && w <= HV_IMAGE_PIXELS_MAX / h;
}
static inline HvImageAlpha hv_image_alpha(const uint8_t *p, size_t w, size_t h, size_t row) {
    HvImageAlpha a = {.left = w};
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        unsigned v = p[y * row + x * 4 + 3];
        if (v <= 15) continue;
        a.content++;
        if (v >= 245) a.opaque++;
        if (!a.present) a.top = y;
        a.present = 1; a.bottom = y;
        if (x < a.left) a.left = x;
        if (x > a.right) a.right = x;
    }
    return a;
}
static inline int hv_image_fixed(size_t w, size_t h) {
    if (w == 1417 && h == 2362) return 1;
    return w >= 4498 && w <= 4502 && h >= 5098 && h <= 5102 ? 2 : 0;
}
static inline HvImagePlan hv_image_plan(size_t w, size_t h, HvImageAlpha a, int pad) {
    HvImagePlan p = {.crop_w = a.present ? a.right - a.left + 1 : w,
                     .crop_h = a.present ? a.bottom - a.top + 1 : h, .fixed = hv_image_fixed(w, h)};
    p.padding = !p.fixed && pad ? 20 : 0;
    size_t pw = p.crop_w + 2 * p.padding, ph = p.crop_h + 2 * p.padding, edge = pw > ph ? pw : ph;
    double scale = p.fixed || hv_image_fixed(pw, ph) == 2 ? 1 : edge < 1500 ? 1500.0 / edge : edge > 3500 ? 3500.0 / edge : 1;
    p.width = (size_t)(pw * scale + 0.5); p.height = (size_t)(ph * scale + 0.5);
    return p;
}
/* Pixels are premultiplied RGBA; Canvas getImageData uses straight RGBA. */
static inline int hv_image_background(const uint8_t *p, size_t w, size_t h, size_t row, HvImageAlpha a, unsigned rgb[3]) {
    rgb[0] = rgb[1] = rgb[2] = 255;
    if (w < 20 || h < 20 || !a.present || a.right - a.left < 10 || a.bottom - a.top < 10) return 0;
    size_t area = (a.right - a.left + 1) * (a.bottom - a.top + 1);
    if ((double)a.opaque / area < 0.985 || (double)(area - a.content) / area > 0.01) return 0;
    size_t xs[2] = {a.left + 3, a.right >= 8 ? a.right - 8 : 0};
    size_t ys[2] = {a.top + 3, a.bottom >= 8 ? a.bottom - 8 : 0};
    unsigned first[3] = {0};
    for (unsigned corner = 0; corner < 4; corner++) {
        size_t x = xs[corner & 1], y = ys[corner >> 1];
        if (x > w - 5) x = w - 5;
        if (y > h - 5) y = h - 5;
        unsigned sums[4] = {0};
        for (size_t yy = y; yy < y + 5; yy++) for (size_t xx = x; xx < x + 5; xx++) {
            const uint8_t *v = p + yy * row + xx * 4;
            for (unsigned c = 0; c < 3; c++) sums[c] += v[3] ? (unsigned)((v[c] * 255u + v[3] / 2) / v[3]) : 0;
            sums[3] += v[3];
        }
        if ((sums[3] + 12) / 25 < 245) return 0;
        for (unsigned c = 0; c < 3; c++) {
            unsigned value = (sums[c] + 12) / 25;
            if (!corner) first[c] = value;
            else if (value > first[c] + 20 || first[c] > value + 20) return 0;
        }
    }
    for (unsigned c = 0; c < 3; c++) rgb[c] = first[c];
    return 1;
}
#endif
