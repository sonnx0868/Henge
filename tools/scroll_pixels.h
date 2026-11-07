#ifndef HENGE_SCROLL_PIXELS_H
#define HENGE_SCROLL_PIXELS_H

#include <math.h>

typedef struct HvScrollPixelMapper {
    double rest_x, rest_y, scale;
} HvScrollPixelMapper;

typedef struct HvScrollPixelFrame { int x, y; } HvScrollPixelFrame;

/* Bound raw motion BEFORE applying the user's gain. A fixed pixel cap after
   gain makes different slider positions indistinguishable under backpressure. */
static inline HvScrollPixelFrame hv_scroll_pixels_apply(HvScrollPixelMapper *m, double x, double y, double scale) {
    scale = isfinite(scale) ? fmin(fmax(scale, 0.1), 1.5) : 0.3;
    if (m->scale != scale) m->rest_x = m->rest_y = 0;
    m->scale = scale;
    x = isfinite(x) ? fmin(fmax(x, -32), 32) : 0;
    y = isfinite(y) ? fmin(fmax(y, -32), 32) : 0;
    double dx = x * (scale / 0.3) + m->rest_x, dy = y * (scale / 0.3) + m->rest_y;
    HvScrollPixelFrame frame = {(int)dx, (int)dy};
    m->rest_x = dx - frame.x;
    m->rest_y = dy - frame.y;
    return frame;
}

#endif
