#ifndef HENGE_PVG_VIDEO_LAYOUT_H
#define HENGE_PVG_VIDEO_LAYOUT_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { HV_PVG_DESC_V1_BYTES = 24, HV_PVG_DESC_V2_BYTES = 39 };

typedef struct __attribute__((packed)) HvPvgMappedHeader {
    uint64_t mapping;
    uint32_t tag, size, ref;
} HvPvgMappedHeader;

typedef int (*HvPvgRead)(void *context, uint32_t task, uint64_t address, void *out, uint32_t bytes);

static inline int hv_pvg_read_mapped_descriptor(HvPvgRead read, void *context, uint32_t task, uint64_t address,
                                               HvPvgMappedHeader *header, uint8_t out[HV_PVG_DESC_V2_BYTES]) {
    _Static_assert(sizeof(HvPvgMappedHeader) == 20, "mapped texture header layout");
    if (read(context, task, address, header, sizeof *header)) return -1;
    uint32_t bytes = header->tag == 0x39 ? HV_PVG_DESC_V2_BYTES : HV_PVG_DESC_V1_BYTES;
    if (address > UINT64_MAX - sizeof *header) return -1;
    memset(out, 0, HV_PVG_DESC_V2_BYTES);
    return read(context, task, address + sizeof *header, out, bytes);
}

typedef struct HvPvgVideoPlane {
    uint64_t offset, stride, rows, row_bytes;
} HvPvgVideoPlane;

static inline int hv_pvg_video_plane_valid(HvPvgVideoPlane p, uint64_t source_bytes,
                                          size_t destination_stride, size_t destination_rows) {
    if (!p.rows || p.rows > destination_rows || !p.row_bytes || p.row_bytes > p.stride ||
        p.row_bytes > destination_stride || p.offset > source_bytes) return 0;
    uint64_t available = source_bytes - p.offset;
    if (available < p.row_bytes || !p.stride) return 0;
    return p.rows - 1 <= (available - p.row_bytes) / p.stride;
}

static inline void hv_pvg_video_plane_copy(uint8_t *destination, size_t destination_stride,
                                          const uint8_t *source, HvPvgVideoPlane plane) {
    for (uint64_t row = 0; row < plane.rows; row++)
        memcpy(destination + row * destination_stride, source + plane.offset + row * plane.stride, (size_t)plane.row_bytes);
}

#endif
