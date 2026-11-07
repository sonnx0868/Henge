#include "share.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static int line(int fd, char *buf, size_t cap) {
    size_t at = 0;
    while (at + 1 < cap) {
        char c;
        if (recv(fd, &c, 1, 0) != 1) return -1;
        buf[at++] = c;
        if (c == '\n') { buf[at] = 0; return 0; }
    }
    return -1;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    char folder[] = "/tmp/henge-scroll-XXXXXX", path[108];
    if (!mkdtemp(folder)) return 1;
    snprintf(path, sizeof path, "%s/s.sock", folder);
    if (hv_share_start(folder, path, NULL) != 0 || hv_share_scroll_ready() || hv_share_scroll_pixels(1, 1)) return 1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct timeval timeout = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 1;
    const char request[] = "GET /.henge/scroll HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n";
    if (send(fd, request, sizeof request - 1, 0) != sizeof request - 1) return 1;
    char buf[256];
    if (line(fd, buf, sizeof buf) || !strstr(buf, "200 OK")) return 1;
    do { if (line(fd, buf, sizeof buf)) return 1; } while (strcmp(buf, "\r\n"));
    for (int i = 0; i < 100 && !hv_share_scroll_ready(); i++) usleep(10000);
    if (!hv_share_scroll_pixels(41, -9) || line(fd, buf, sizeof buf)) return 1;
    int x, y;
    if (sscanf(buf, "%d %d", &x, &y) != 2 || x != 41 || y != -9) return 1;
    if (!hv_share_scroll_pixels(400, -400) || line(fd, buf, sizeof buf)) return 1;
    if (sscanf(buf, "%d %d", &x, &y) != 2 || x != 128 || y != -128) return 1;
    shutdown(fd, SHUT_RDWR);
    close(fd);
    for (int i = 0; i < 400 && hv_share_scroll_ready(); i++) usleep(10000);
    int ready = hv_share_scroll_ready();
    unlink(path);
    rmdir(folder);
    if (ready || hv_share_scroll_pixels(1, 1)) return 1;
    puts("scroll bridge: disconnected fallback, stream delivery, bounded queue and disconnect detection passed");
    return 0;
}
