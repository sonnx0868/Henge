/* Run the production exec/completion/presenter scheduling without a physical GPU.
   Reproduce a scanout updated in place: no swap command and no cursor input. */
#include "../devices/pvg_metal.m"
#include <assert.h>

/* Only the serialized render pass below is guest-readable. */
static uint8_t guest_commands[8 + 8 + 0x248];
int hv_pvg_lite_task_read(HvPvgLite *p, uint32_t t, uint64_t a, void *o, uint32_t n) {
    assert(a == 0x1000 && n == sizeof guest_commands);
    memcpy(o, guest_commands, n);
    return 0;
}
void hv_pvg_lite_task_pages(HvPvgLite *p, uint32_t t, uint64_t a, uint64_t n, uint32_t *o) { abort(); }
uint8_t *hv_pvg_lite_page(HvPvgLite *p, uint32_t n) { abort(); }
void *hv_pvg_lite_phys(HvPvgLite *p, uint64_t a, uint64_t n) { abort(); }
uint64_t hv_pvg_lite_task_objects(HvPvgLite *p, uint32_t t) { abort(); }
const uint8_t *hv_pvg_lite_surface(HvPvgLite *p, uint32_t n) { abort(); }
uint8_t *hv_pvg_lite_display_page(HvPvgLite *p) { abort(); }
void hv_pvg_lite_command(HvPvgLite *p, const uint32_t *c, uint32_t n) { abort(); }
static unsigned stamps;
void hv_pvg_lite_complete(HvPvgLite *p, uint32_t c, uint32_t s) { stamps++; }

@interface TestTexture : NSObject
@property(nonatomic, strong) id<MTLBuffer> buffer;
@property(nonatomic, strong) id<MTLTexture> parentTexture;
@property NSUInteger bufferOffset, bufferBytesPerRow, height;
@property MTLTextureType textureType;
@end
@implementation TestTexture
@end

@interface TestBuffer : NSObject
@property NSUInteger length;
@end
@implementation TestBuffer
@end

@interface TestEncoder : NSObject
@end
@implementation TestEncoder
- (void)endEncoding {}
@end

@interface TestCB : NSObject
@property(nonatomic, strong) NSMutableArray *handlers;
@property(nonatomic, strong) NSError *error;
@property MTLCommandBufferStatus status;
@end
@implementation TestCB
- (instancetype)init { if ((self = [super init])) _handlers = [NSMutableArray new]; return self; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { [_handlers addObject:[handler copy]]; }
- (void)commit { _status = MTLCommandBufferStatusCommitted; }
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor { return [TestEncoder new]; }
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
    HvObject *resource, *aliasResource;
}
@end
@implementation TestReplay
- (HvObject *)object:(uint32_t)ref task:(uint32_t)task { return ref == 1 ? resource : ref == 2 ? aliasResource : nil; }
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
        TestTexture *scanout = [TestTexture new];
        TestBuffer *backing = [TestBuffer new];
        backing.length = 8192;
        scanout.buffer = (id<MTLBuffer>)backing;
        scanout.bufferBytesPerRow = 256;
        scanout.height = 16;
        scanout.textureType = MTLTextureType2D;
        r->screen_tex = (id<MTLTexture>)scanout;
        r->resource = [HvObject new];
        r->resource->surface = [HvObject new];
        r->resource->surface->scanout = r->screen_tex;
        uint32_t exec[5] = {0, 1, 0, 1, 2}; /* one writable visible resource */
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
        /* Offscreen writes and read-only sampling of the visible surface
           must not generate extra display frames. */
        for (unsigned flags = 1; flags <= 2; flags++) {
            q.next = [TestCB new];
            exec[4] = flags;
            if (flags == 2) r->resource->surface->scanout = nil;
            assert([r exec:exec length:sizeof exec channel:1 stamp:6 + flags]);
            [q.next finish:YES];
            dispatch_sync(r->presenter, ^{});
            assert(r->displayed == 3);
        }
        assert(!r->screen_dirty && !r->presenter_running);
        /* A real render attachment writes scanout despite missing resource write
           flags and a distinct view with no HvObject.surface association. */
        TestTexture *target = [TestTexture new], *view = [TestTexture new];
        target.buffer = scanout.buffer;
        target.bufferBytesPerRow = scanout.bufferBytesPerRow;
        target.height = scanout.height;
        target.textureType = MTLTextureType2D;
        view.parentTexture = (id<MTLTexture>)target;
        r->resource->object = view;
        assert([r textureSharesScanout:(id<MTLTexture>)view]);
        uint32_t segment = sizeof guest_commands - 8, info = 0, tag = 26, record = 8 + 0x248;
        memcpy(guest_commands, &segment, 4);
        memcpy(guest_commands + 4, &info, 4);
        memcpy(guest_commands + 8, &tag, 4);
        memcpy(guest_commands + 12, &record, 4);
        uint32_t ref = 1;
        uint16_t store = MTLStoreActionStore;
        memcpy(guest_commands + 16 + 0x4c, &ref, 4);
        memcpy(guest_commands + 16 + 0x4c + 22, &store, 2);
        struct __attribute__((packed)) {
            uint32_t task, nres, nbuf, ref, flags;
            uint64_t offset, length;
        } attachment_exec = {0, 1, 1, 1, 1, 0x1000, sizeof guest_commands};
        for (unsigned scenario = 0; scenario < 3; scenario++) {
            if (scenario == 2) target.bufferOffset = 4096; /* offscreen in SAME backing allocation */
            q.next = [TestCB new];
            assert([r exec:(const uint32_t *)&attachment_exec length:sizeof attachment_exec channel:1 stamp:10 + scenario]);
            dispatch_sync(r->presenter, ^{});
            assert(r->displayed == 3 + (scenario > 0));
            [q.next finish:scenario != 1]; /* failed visible write must not wake */
            dispatch_sync(r->presenter, ^{});
            assert(r->displayed == 4);
        }
        assert(!r->screen_dirty && !r->presenter_running);
        /* Real two-plane IOSurface, two resource views: the production exec
           must inspect/upload once, then recheck on the next submission. */
        HvObject *video = [HvObject new];
        uint8_t descriptor[0x200] = {0};
        uint32_t fourcc = '420v';
        uint64_t width = 64, height = 64;
        memcpy(descriptor + 4, &fourcc, 4);
        memcpy(descriptor + 0x20, &width, 8);
        memcpy(descriptor + 0x28, &height, 8);
        descriptor[0x3e] = 2;
        for (unsigned plane = 0; plane < 2; plane++) {
            uint8_t *d = descriptor + 0x80 + plane * 0x80;
            uint64_t offset = plane ? 4096 : 0, bytes = plane ? 2048 : 4096;
            uint64_t w = plane ? 32 : 64, h = w, row = 64;
            uint16_t element = plane ? 2 : 1;
            memcpy(d + 8, &offset, 8); memcpy(d + 0x18, &bytes, 8);
            memcpy(d + 0x20, &w, 8); memcpy(d + 0x28, &h, 8);
            memcpy(d + 0x30, &row, 8); memcpy(d + 0x38, &element, 2);
        }
        video->alloc = 6144;
        video->length = 16384;
        vm_address_t pixels = 0;
        assert(vm_allocate(mach_task_self(), &pixels, video->length, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
        video->mapped = (uint8_t *)pixels;
        video->iosurface = make_iosurface(video, descriptor, video->alloc);
        assert(video->iosurface);
        r->resource->surface = video;
        r->aliasResource = [HvObject new];
        r->aliasResource->surface = video;
        uint32_t video_exec[] = {0, 2, 0, 1, 1, 2, 1};
        for (unsigned frame = 0; frame < 3; frame++) {
            if (frame < 2) video->mapped[0] = (uint8_t)(frame + 1);
            q.next = [TestCB new];
            assert([r exec:video_exec length:sizeof video_exec channel:1 stamp:20 + frame]);
            [q.next finish:YES];
            assert(r->video_deduplicated == frame + 1);
            assert(r->video_uploads == (frame ? 2 : 1));
            assert(r->video_skips == (frame == 2 ? 1 : 0));
            assert(!r->video_copy_failures);
            assert(*(uint8_t *)IOSurfaceGetBaseAddressOfPlane(video->iosurface, 0) == (frame ? 2 : 1));
        }
        dispatch_sync(r->presenter, ^{});
        assert(r->displayed == 4 && !r->screen_dirty && !r->presenter_running);
        puts("PVG present: actual scanout attachments wake after successful completion without resource write flags or input; offscreen/read-only work and failed jobs stay idle");
        puts("PVG video: aliased plane resources check once per exec; changed and unchanged submissions are rechecked");
    }
    return 0;
}
