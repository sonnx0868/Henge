#include <stdio.h>
#include "../tools/scroll_pixels.h"
#include "../tools/scroll_wheel.h"

#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); return 1; } } while (0)

int main(void) {
    const double raw[] = {9.06, 3.79, 4.47, 4.05, 3.90, 3.98, 3.98, 14.42,
                          3.75, 4.68, 4.34, 4.82, 4.99, 6.51, 33.32, 7.46, 8.28};
    const double scales[] = {0.1, 0.3, 1.5};
    int totals[3] = {0};
    for (int s = 0; s < 3; s++) {
        HvScrollPixelMapper mapper = {0};
        for (unsigned i = 0; i < sizeof raw / sizeof raw[0]; i += 2) {
            double frame = raw[i] + (i + 1 < sizeof raw / sizeof raw[0] ? raw[i + 1] : 0);
            frame = fmin(frame, 16); /* iPad raw-frame limit */
            HvScrollPixelFrame result = hv_scroll_pixels_apply(&mapper, 0, frame, scales[s]);
            totals[s] += result.y;
            CHECK(result.x == 0 && result.y >= 0, "direction is preserved");
        }
        CHECK(hv_scroll_pixels_apply(&mapper, 0, 0, scales[s]).y == 0, "no motion backlog");
    }
    CHECK(totals[0] > 0 && totals[1] > totals[0] && totals[2] > totals[1], "all slider positions affect output");
    CHECK(totals[2] >= 14 * totals[0], "0.1 to 1.5 retains its 15x gain through the full path");
    HvScrollPixelMapper low = {0}, high = {0};
    HvScrollPixelFrame a = hv_scroll_pixels_apply(&low, 0, 1000000, 0.1);
    HvScrollPixelFrame b = hv_scroll_pixels_apply(&high, 0, 1000000, 1.5);
    CHECK(a.y == 10 && b.y == 160, "backpressure limit is applied before gain, not after it");
    HvScrollPixelMapper fine = {0};
    int pixels = 0;
    for (int i = 0; i < 4; i++) pixels += hv_scroll_pixels_apply(&fine, 0, 0.75, 0.1).y;
    CHECK(pixels == 1, "small motion survives fractional pixel accumulation");
    CHECK(hv_scroll_pixels_apply(&fine, NAN, INFINITY, 0.1).x == 0, "invalid raw values are ignored");
    HvScrollPixelMapper wheel = {0};
    for (int i = 0; i < 5; i++)
        CHECK(hv_scroll_pixels_apply(&wheel, 0, 32, 0.3).y == 32, "converted isolated wheel unit survives guest delivery");
    CHECK(hv_scroll_pixels_apply(&wheel, -4, 0, 0.3).x == -4, "fractional horizontal wheel conversion survives guest delivery");
    HvScrollWheel burst = {0};
    hv_scroll_wheel_append(&burst, 0, 5 * 32 * 5, 1); // five coalesced notches at the user's 5x setting
    int fast = 0, frames = 0;
    while (hv_scroll_wheel_pending(&burst) && frames < 30) {
        HvScrollWheelFrame f = hv_scroll_wheel_take(&burst, 1 + (++frames) / 60.0);
        CHECK(f.x == 0 && f.y > 0 && f.y <= 256, "wheel is interpolated in bounded pixel steps");
        if (frames == 1) CHECK(f.y < 800, "a burst is not posted as one jump");
        fast += f.y;
    }
    CHECK(fast == 800 && !hv_scroll_wheel_pending(&burst), "fast five-notch burst retains its full distance");
    HvScrollWheel isolated = {0};
    int slow = 0;
    for (int notch = 0; notch < 5; notch++) {
        double now = 1 + notch * 0.25;
        hv_scroll_wheel_append(&isolated, 0, 160, now);
        for (int frame = 1; hv_scroll_wheel_pending(&isolated) && frame <= 15; frame++)
            slow += hv_scroll_wheel_take(&isolated, now + frame / 60.0).y;
    }
    CHECK(slow == fast, "slow and fast wheel gestures have equal total travel");
    hv_scroll_wheel_append(&burst, 0, 1280, 3);
    CHECK(hv_scroll_wheel_take(&burst, 3.6).y == 0, "a severely stalled wheel queue expires rather than replaying late");
    for (int i = 0; i < 4; i++) {
        hv_scroll_wheel_append(&burst, 0.25, 0, 4 + i * 0.01);
        CHECK(hv_scroll_wheel_take(&burst, 4 + i * 0.01).x == (i == 3 ? 1 : 0), "wheel fractions accumulate");
    }
    int isolated_fraction = 0;
    for (int i = 0; i < 3; i++) {
        hv_scroll_wheel_append(&burst, 0, 0.4, 5 + i);
        isolated_fraction += hv_scroll_wheel_take(&burst, 5 + i).y;
    }
    CHECK(isolated_fraction == 1, "fractional wheel motion survives one-second gaps between slow notches");
    HvScrollLine parsed;
    CHECK(hv_scroll_parse_line("41.000000 -9.000000 0.100000", &parsed) && parsed.kind == 'P' && parsed.x == 41,
          "new helper accepts original v2 numeric messages");
    CHECK(hv_scroll_parse_line("W 0 800 1.5", &parsed) && parsed.kind == 'W' && parsed.y == 800,
          "typed wheel stream bypasses raw trackpad caps");
    CHECK(!hv_scroll_parse_line("P 0 800 1.5", &parsed) && !hv_scroll_parse_line("W nan 2 0.3", &parsed) &&
          !hv_scroll_parse_line("X 0 2 0.3", &parsed), "typed stream rejects invalid kind, range and nonfinite values");
    printf("smooth wheel: fast/slow five-notch distance %d/%d pixels, %d frames; v2/v3 parsing passed\n", fast, slow, frames);
    printf("scroll pixels: replay totals at 0.1/0.3/1.5 = %d/%d/%d; gain, backpressure, idle and subpixel checks passed\n",
           totals[0], totals[1], totals[2]);
    return 0;
}
