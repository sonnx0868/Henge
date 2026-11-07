#include <stdio.h>
#include "pvg_video_layout.h"

#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); return 1; } } while (0)

typedef struct Guest { uint8_t bytes[80]; size_t size; uint32_t last_read; } Guest;
static int read_guest(void *context, uint32_t task, uint64_t address, void *out, uint32_t bytes) {
    (void)task;
    Guest *g = context;
    g->last_read = bytes;
    if (address > g->size || bytes > g->size - address) return -1;
    memcpy(out, g->bytes + address, bytes);
    return 0;
}

int main(void) {
    Guest g = {0};
    HvPvgMappedHeader header = {.mapping = 42, .tag = 0x39, .size = 39, .ref = 7}, got;
    g.size = sizeof header + HV_PVG_DESC_V2_BYTES;
    memcpy(g.bytes, &header, sizeof header);
    for (int i = 0; i < 4; i++) g.bytes[sizeof header + 35 + i] = (uint8_t)i;
    uint8_t descriptor[HV_PVG_DESC_V2_BYTES + 1];
    memset(descriptor, 0xaa, sizeof descriptor);
    CHECK(hv_pvg_read_mapped_descriptor(read_guest, &g, 0, 0, &got, descriptor) == 0, "complete v2 descriptor reads successfully");
    CHECK(g.last_read == 39 && descriptor[35] == 0 && descriptor[36] == 1 && descriptor[37] == 2 && descriptor[38] == 3,
          "all v2 channel swizzles are read from guest memory");
    CHECK(descriptor[39] == 0xaa, "descriptor output stays within bounds");
    g.size = sizeof header + 32;
    CHECK(hv_pvg_read_mapped_descriptor(read_guest, &g, 0, 0, &got, descriptor) != 0, "truncated 32-byte v2 descriptor is rejected");
    header.tag = 0x16;
    memcpy(g.bytes, &header, sizeof header);
    g.size = sizeof header + 24;
    CHECK(hv_pvg_read_mapped_descriptor(read_guest, &g, 0, 0, &got, descriptor) == 0 && g.last_read == 24,
          "v1 reads only its own 24 bytes");

    uint8_t source[96], destination[64];
    for (unsigned i = 0; i < sizeof source; i++) source[i] = (uint8_t)i;
    memset(destination, 0xcc, sizeof destination);
    HvPvgVideoPlane plane = {.offset = 7, .stride = 12, .rows = 3, .row_bytes = 8};
    CHECK(hv_pvg_video_plane_valid(plane, 39, 16, 3), "last row does not require unused source padding");
    hv_pvg_video_plane_copy(destination, 16, source, plane);
    for (int row = 0; row < 3; row++) {
        CHECK(memcmp(destination + row * 16, source + 7 + row * 12, 8) == 0, "visible row copied using independent strides");
        for (int i = 8; i < 16; i++) CHECK(destination[row * 16 + i] == 0xcc, "destination padding is not overwritten");
    }
    CHECK(destination[48] == 0xcc, "copy stays inside the destination plane");
    CHECK(!hv_pvg_video_plane_valid(plane, 38, 16, 3), "short source plane rejected");
    CHECK(!hv_pvg_video_plane_valid(plane, 96, 7, 3), "short destination stride rejected");
    CHECK(!hv_pvg_video_plane_valid(plane, 96, 16, 2), "short destination height rejected");
    plane.offset = UINT64_MAX;
    CHECK(!hv_pvg_video_plane_valid(plane, 96, 16, 3), "offset overflow rejected");
    puts("PVG video: v1/v2 descriptor bounds, channel swizzles, row strides, padding and truncated planes passed");
    return 0;
}
