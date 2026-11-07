/* Run the production exec/completion/presenter scheduling without a physical GPU.
   Reproduce a scanout updated in place: no swap command and no cursor input. */
#include "../devices/pvg_metal.m"
#include <assert.h>

/* No guest memory is needed for an empty exec. Any unexpected access fails. */
int hv_pvg_lite_task_read(HvPvgLite *p, uint32_t t, uint64_t a, void *o, uint32_t n) { abort(); }
void hv_pvg_lite_task_pages(HvPvgLite *p, uint32_t t, uint64_t a, uint64_t n, uint32_t *o) { abort(); }
uint8_t *hv_pvg_lite_page(HvPvgLite *p, uint32_t n) { abort(); }
void *hv_pvg_lite_phys(HvPvgLite *p, uint64_t a, uint64_t n) { abort(); }
uint64_t hv_pvg_lite_task_objects(HvPvgLite *p, uint32_t t) { abort(); }
const uint8_t *hv_pvg_lite_surface(HvPvgLite *p, uint32_t n) { abort(); }
uint8_t *hv_pvg_lite_display_page(HvPvgLite *p) { abort(); }
void hv_pvg_lite_command(HvPvgLite *p, const uint32_t *c, uint32_t n) { abort(); }
static unsigned stamps;
void hv_pvg_lite_complete(HvPvgLite *p, uint32_t c, uint32_t s) { stamps++; }

@interface TestCB : NSObject
@property(nonatomic, strong) NSMutableArray *handlers;
@property(nonatomic, strong) NSError *error;
@property MTLCommandBufferStatus status;
@end
@implementation TestCB
- (instancetype)init { if ((self = [super init])) _handlers = [NSMutableArray new]; return self; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { [_handlers addObject:[handler copy]]; }
- (void)commit { _status = MTLCommandBufferStatusCommitted; }
- (void)waitUntilCompleted { abort(); } /* refresh must never block the worker */
- (void)finish:(BOOL)success {
    _status = success ? MTLCommandBufferStatusCompleted : MTLCommandBufferStatusError;
    _error = success ? nil : [NSError errorWithDomain:@"test" code:1 userInfo:nil];
    NSArray *callbacks = [_handlers copy];
    [_handlers removeAllObjects];
    for (MTLCommandBufferHandler callback in callbacks) callback((id<MTLCommandBuffer>)self);
}
@end

@interface TestQueue : NSObject
@property(nonatomic, strong) TestCB *next;
@end
@implementation TestQueue
- (id)commandBuffer { return _next; }
@end

@interface TestReplay : HvReplay {
@public
    unsigned displayed;
}
@end
@implementation TestReplay
/* Keep the real dirty flag, lock and kickPresenter; replace only Metal drawing. */
- (void)presentLoop {
    os_unfair_lock_lock(&screen_lock);
    assert(screen_dirty);
    displayed++;
    screen_dirty = NO;
    presenter_running = NO;
    os_unfair_lock_unlock(&screen_lock);
}
@end

int main(void) {
    @autoreleasepool {
        unsetenv("HV_PVG_SYNC");
        TestReplay *r = [TestReplay new];
        TestQueue *q = [TestQueue new];
        r->queue = (id<MTLCommandQueue>)q;
        r->presenter = dispatch_queue_create("test.present", DISPATCH_QUEUE_SERIAL);
        r->screen_lock = OS_UNFAIR_LOCK_INIT;
        /* A retained scanout exists; the test presenter does not sample it. */
        r->screen_tex = (id<MTLTexture>)[NSObject new];
        uint32_t exec[3] = {0, 0, 0};
        for (unsigned i = 0; i < 3; i++) {
            q.next = [TestCB new];
            assert([r exec:exec length:sizeof exec channel:1 stamp:i]);
            assert(atomic_load(&r->inflight) == 1);
            dispatch_sync(r->presenter, ^{});
            assert(r->displayed == i); /* never refresh before GPU completion */
            [q.next finish:YES];
            dispatch_sync(r->presenter, ^{});
            assert(r->displayed == i + 1); /* resumes after every idle period */
            assert(atomic_load(&r->inflight) == 0);
        }
        assert(stamps == 3 && r->screen_swaps == 0);
        assert(atomic_load(&r->gpu_redraws) == 3);
        q.next = [TestCB new];
        assert([r exec:exec length:sizeof exec channel:1 stamp:4]);
        [q.next finish:NO];
        dispatch_sync(r->presenter, ^{});
        assert(r->displayed == 3 && r->failed == 1 && stamps == 4);
        /* Empty stamp fences must not keep the display awake. */
        q.next = [TestCB new];
        [r commit:(id<MTLCommandBuffer>)q.next channel:1 stamp:5 complete:YES redraw:NO];
        [q.next finish:YES];
        dispatch_sync(r->presenter, ^{});
        assert(r->displayed == 3 && stamps == 5);
        assert(!r->screen_dirty && !r->presenter_running);
        puts("PVG present: GPU completion wakes idle scanout without swaps/input; failed jobs and stamp fences do not redraw");
    }
    return 0;
}
