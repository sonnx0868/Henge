#ifndef HV_IMAGE_SERVICE_H
#define HV_IMAGE_SERVICE_H
#include <stddef.h>
#include <stdint.h>
/* HTTP status; on 200, caller frees the length-prefixed metadata/PNG envelope. */
int hv_native_image_process(const uint8_t *input, size_t bytes, int extension, int pad, int analyze,
                            uint8_t **output, size_t *output_bytes);
#endif
