#include "share.h"
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
static char path[108];
static int mock(const uint8_t *p, size_t n, int extension, int pad, int analyze, uint8_t **out, size_t *bytes) {
    assert(n == 4 && p[0] == 0 && p[3] == 255 && extension == 1 && pad == 1 && analyze == 0);
    *bytes = 6; *out = malloc(6); memcpy(*out, "\0\0\0\2{}", 6); return 200;
}
static int request(const char *headers, const uint8_t *body, size_t n, char *out, size_t cap) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX}; strcpy(addr.sun_path, path);
    struct timeval timeout = {.tv_sec = 3}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    assert(connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0);
    assert(send(fd, headers, strlen(headers), 0) == (ssize_t)strlen(headers));
    if (n) assert(send(fd, body, n, 0) == (ssize_t)n);
    size_t total = 0; ssize_t got;
    while (total + 1 < cap && (got = recv(fd, out + total, cap - total - 1, 0)) > 0) total += (size_t)got;
    out[total] = 0; close(fd); int status = 0; assert(sscanf(out, "HTTP/1.1 %d", &status) == 1); return status;
}
int main(void) {
    signal(SIGPIPE, SIG_IGN);
    char folder[] = "/tmp/henge-image-XXXXXX", output[2048];
    assert(mkdtemp(folder)); snprintf(path, sizeof path, "%s/s.sock", folder);
    assert(hv_share_start(folder, path, NULL) == 0);
    assert(request("GET /.henge/image/v1 HTTP/1.1\r\nConnection: close\r\n\r\n", NULL, 0, output, sizeof output) == 503);
    hv_share_set_image_processor(mock);
    assert(request("GET /.henge/image/v1 HTTP/1.1\r\nConnection: close\r\n\r\n", NULL, 0, output, sizeof output) == 200);
    assert(strstr(output, "native-imageio") && strstr(output, "maxInputBytes"));
    uint8_t bytes[] = {0, 1, 128, 255};
    assert(request("POST /.henge/image/v1/prepare?extension=1&pad=1&analyze=0 HTTP/1.1\r\nContent-Length: 4\r\n\r\n", bytes, 4, output, sizeof output) == 200);
    assert(strstr(output, "application/x-henge-image-v1"));
    assert(request("POST /.henge/image/v1/prepare?extension=2&pad=1&analyze=0 HTTP/1.1\r\nContent-Length: 0\r\n\r\n", NULL, 0, output, sizeof output) == 400);
    assert(request("POST /.henge/image/v1/prepare?extension=1&pad=1&analyze=0 HTTP/1.1\r\nContent-Length: 33554433\r\n\r\n", NULL, 0, output, sizeof output) == 413);
    hv_share_set_image_processor(NULL);
    assert(request("GET /.henge/image/v1 HTTP/1.1\r\nConnection: close\r\n\r\n", NULL, 0, output, sizeof output) == 503);
    unlink(path); rmdir(folder);
    puts("image bridge: capability, binary body, unavailable fallback, query validation and upload cap passed");
    return 0;
}
