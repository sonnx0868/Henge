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

/// A disconnected pixel helper leaves only the guest's accelerated, discrete
/// wheel. Preserve fractional wheel travel across isolated slow notches;
/// waiting between them must not continually erase a low speed setting.
struct ScrollFallback {
    private var x: Float = 0, y: Float = 0
    private var lastEmission = -Double.infinity

    mutating func append(x dx: Float, y dy: Float, kind: ScrollInputKind, scale: Float, now: Double) -> (Int32, Int32) {
        let safeScale = scale.isFinite ? min(max(scale, 0.1), 1.5) : 0.3
        let divisor: Float = kind == .wheel ? 32 : 4
        if dx.isFinite { x = min(max(x + dx / divisor * (safeScale / 0.3), -2), 2) }
        if dy.isFinite { y = min(max(y + dy / divisor * (safeScale / 0.3), -2), 2) }
        guard now.isFinite, now - lastEmission >= 0.05 else { return (0, 0) }
        let sx: Int32 = abs(x) >= 1 ? (x < 0 ? -1 : 1) : 0
        let sy: Int32 = abs(y) >= 1 ? (y < 0 ? -1 : 1) : 0
        guard sx != 0 || sy != 0 else { return (0, 0) }
        x -= Float(sx)
        y -= Float(sy)
        lastEmission = now
        return (sx, sy)
    }
}
