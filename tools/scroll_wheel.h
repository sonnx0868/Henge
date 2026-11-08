#ifndef HENGE_SCROLL_WHEEL_H
#define HENGE_SCROLL_WHEEL_H

#include <math.h>
#include <stdio.h>

/* Already-scaled wheel pixels, independent of the trackpad's raw-motion
   limiter. A short, bounded tail interpolates each burst without losing
   notches merely because they arrived in one scheduler interval. */
typedef struct HvScrollWheel {
    double x, y, last_input;
} HvScrollWheel;
typedef struct HvScrollWheelFrame { int x, y; } HvScrollWheelFrame;

static inline int hv_scroll_wheel_pending(const HvScrollWheel *w) {
    return fabs(w->x) >= 1 || fabs(w->y) >= 1;
}

static inline void hv_scroll_wheel_append(HvScrollWheel *w, double x, double y, double now) {
    if (!isfinite(x) || !isfinite(y) || !isfinite(now)) return;
    if (now < w->last_input || now - w->last_input > 0.5) w->x = w->y = 0;
    w->x = fmin(fmax(w->x + x, -1280), 1280);
    w->y = fmin(fmax(w->y + y, -1280), 1280);
    w->last_input = now;
}

static inline int hv_scroll_wheel_step(double *pending) {
    double whole = floor(fabs(*pending));
    if (whole < 1) return 0;
    int amount = (int)fmin(256, fmax(1, floor(whole * 0.5)));
    int step = *pending < 0 ? -amount : amount;
    *pending -= step;
    return step;
}

static inline HvScrollWheelFrame hv_scroll_wheel_take(HvScrollWheel *w, double now) {
    if (!isfinite(now) || now < w->last_input || now - w->last_input > 0.5) {
        w->x = w->y = 0;
        return (HvScrollWheelFrame){0};
    }
    return (HvScrollWheelFrame){hv_scroll_wheel_step(&w->x), hv_scroll_wheel_step(&w->y)};
}

/* New helpers accept both the negotiated typed stream and old apps' v2
   replies. A leading numeric character must not be mistaken for a type. */
typedef struct HvScrollLine { char kind; double x, y, scale; } HvScrollLine;
static inline int hv_scroll_parse_line(const char *text, HvScrollLine *out) {
    HvScrollLine value = {.kind = 'P'};
    if (!text || !out) return 0;
    if ((text[0] == 'P' || text[0] == 'W') && text[1] == ' ') {
        if (sscanf(text, "%c %lf %lf %lf", &value.kind, &value.x, &value.y, &value.scale) != 4) return 0;
    } else if (sscanf(text, "%lf %lf %lf", &value.x, &value.y, &value.scale) != 3) return 0;
    double bound = value.kind == 'W' ? 1280 : 64;
    if (!isfinite(value.x) || !isfinite(value.y) || !isfinite(value.scale) ||
        fabs(value.x) > bound || fabs(value.y) > bound || value.scale < 0.1 || value.scale > 1.5) return 0;
    *out = value;
    return 1;
}

#endif
