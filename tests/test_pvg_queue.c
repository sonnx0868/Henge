/* Exercise the production device queue with guest memory and a fake Metal
   consumer. No CPU/JIT, input events, real GPU or worker timing is required. */
#include <assert.h>
#include "../devices/pvg_lite.c"

static uint8_t memory[0x30000];
static HvMachine machine;
static unsigned interrupts, submitted;
static int append_while_busy;
static void publish(unsigned ch, uint32_t stamp, unsigned dependency, uint32_t target);

void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) {
    (void)m;
    return pa <= sizeof memory && len <= sizeof memory - pa ? memory + pa : NULL;
}
int hv_machine_add_mmio(HvMachine *m, uint64_t pa, uint64_t size, void *opaque,
                       uint64_t (*read)(void *, uint64_t, unsigned),
                       void (*write)(void *, uint64_t, uint64_t, unsigned), const char *name) {
    (void)m; (void)pa; (void)size; (void)opaque; (void)read; (void)write; (void)name;
    return 0;
}
void hv_gicv3_pend(HvGic *g, int irq) { (void)g; (void)irq; interrupts++; }
void hv_machine_wake(HvMachine *m) { (void)m; }
HvPvgMetal *hv_pvg_metal_create(HvPvgLite *p) { (void)p; return (HvPvgMetal *)1; }
void hv_pvg_metal_set_layer(HvPvgMetal *m, void *l) { (void)m; (void)l; }
uint64_t hv_pvg_metal_gpu_frames(HvPvgMetal *m) { (void)m; return submitted; }
int hv_pvg_metal_snapshot(HvPvgMetal *m, uint8_t *p, uint32_t w, uint32_t h) {
    (void)m; (void)p; (void)w; (void)h; return -1;
}
int hv_pvg_metal_frame(HvPvgMetal *m, const uint8_t **p, uint32_t *w, uint32_t *h) {
    (void)m; (void)p; (void)w; (void)h; return -1;
}
void hv_pvg_metal_cursor_moved(HvPvgMetal *m) { (void)m; abort(); }
void hv_pvg_metal_unmap(HvPvgMetal *m, uint32_t mapping) { (void)m; (void)mapping; }
void hv_pvg_metal_submit(HvPvgMetal *m, HvPvgLite *p, uint32_t ch, uint32_t *cmd, uint32_t len) {
    (void)m; (void)len;
    submitted++;
    if (append_while_busy) {
        append_while_busy = 0;
        /* Producer adds work while the consumer still advertises a nonempty
           queue. It does not issue another empty-to-nonempty notification. */
        publish(1, 2, 0, 0);
    }
    hv_pvg_lite_complete(p, ch, cmd[2]);
    free(cmd);
}

static uint32_t *record(unsigned ch) { return (uint32_t *)(memory + 0x4400 + 0x14 * (ch - 1)); }
static void publish(unsigned ch, uint32_t stamp, unsigned dependency, uint32_t target) {
    uint32_t *rec = record(ch), at = rec[0];
    uint32_t *cmd = (uint32_t *)(memory + (ch == 1 ? 0x10000 : 0x14000) + at);
    cmd[0] = 0x99 | (dependency ? 1u << 16 : 0); /* inert command, with a real queue stamp */
    cmd[1] = dependency ? 20 : 12;
    cmd[2] = stamp;
    if (dependency) cmd[3] = dependency, cmd[4] = target;
    __atomic_store_n(&rec[0], at + cmd[1], __ATOMIC_RELEASE);
}

int main(void) {
    machine.ncpus = 1;
    HvPvgLite *p = hv_pvg_lite_create(&machine, NULL, 0, 0, 49, 48);
    p->regs[0x1c / 4] = 1; /* root PA 0x4000 */
    p->regs[0x30 / 4] = 2; /* completion stamps PA 0x8000 */
    record(1)[4] = 3; /* page table PA 0xc000 */
    record(2)[4] = 6; /* page table PA 0x18000 */
    *(uint32_t *)(memory + 0xc000) = 4;
    *(uint32_t *)(memory + 0x18000) = 5;

    /* A second batch arrives during the first doorbell's drain, after its wr
       snapshot. The consumer must discover it without another input/doorbell. */
    publish(1, 1, 0, 0);
    append_while_busy = 1;
    gfx_write(p, 0x1020, 1, 4);
    assert(submitted == 1 && record(1)[1] == 12 && record(1)[0] == 24);
    hv_pvg_lite_poll(p);
    assert(submitted == 2 && record(1)[1] == 24);
    assert(*(uint32_t *)(memory + 0x8004) == 2 && interrupts > 0);
    assert(p->poll_recoveries == 1);

    /* An idle tick creates no synthetic GPU submissions or interrupts. */
    unsigned before = interrupts;
    hv_pvg_lite_poll(p);
    assert(submitted == 2 && interrupts == before);

    /* Preserve barriers: do not pass a stamp that has not been published. */
    publish(1, 3, 2, 7);
    hv_pvg_lite_poll(p);
    assert(submitted == 2 && record(1)[1] == 24 && (p->chan_pending & 2));
    publish(2, 7, 0, 0);
    hv_pvg_lite_poll(p);
    assert(submitted == 4 && record(1)[1] == record(1)[0]);
    assert(*(uint32_t *)(memory + 0x8004) == 3 && *(uint32_t *)(memory + 0x8008) == 7);
    assert(p->barrier_timeouts == 0 && p->barrier_drains > 0);
    puts("PVG queue: later batches progress without input/doorbells; empty ticks stay idle and dependencies remain ordered");
    free(p);
    return 0;
}
