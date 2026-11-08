/// Bound raw pad motion per display interval. The Mac helper applies the user's
/// scale after its own coalescing, so downstream limits cannot erase the gain.
enum ScrollInputKind: String, CaseIterable {
    case precision, wheel
}

struct ScrollMotion {
    private var x: Float = 0, y: Float = 0
    private let kind: ScrollInputKind

    init(kind: ScrollInputKind = .precision) { self.kind = kind }

    mutating func append(x dx: Float, y dy: Float) {
        // A wheel unit needs useful pixel travel, rather than being treated as
        // a single trackpad pixel. This conversion is explicitly selected by
        // the user; device names and delta sizes never classify the hardware.
        let unit: Float = kind == .wheel ? 32 : 1
        if dx.isFinite { x += min(max(dx, -64), 64) * unit }
        if dy.isFinite { y += min(max(dy, -64), 64) * unit }
    }

    mutating func takeFrame() -> (Float, Float) {
        var dx = x, dy = y
        if abs(dy) > 2 * abs(dx) { dx = 0 }
        else if abs(dx) > 2 * abs(dy) { dy = 0 }
        let limit: Float = kind == .wheel ? 32 : 16
        dx = min(max(dx, -limit), limit)
        dy = min(max(dy, -limit), limit)
        x = 0
        y = 0
        return (dx, dy)
    }
}
