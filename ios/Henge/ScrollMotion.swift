/// Bound raw pad motion per display interval. The Mac helper applies the user's
/// scale after its own coalescing, so downstream limits cannot erase the gain.
struct ScrollMotion {
    private var x: Float = 0, y: Float = 0

    mutating func append(x dx: Float, y dy: Float) {
        if dx.isFinite { x += min(max(dx, -64), 64) }
        if dy.isFinite { y += min(max(dy, -64), 64) }
    }

    mutating func takeFrame() -> (Float, Float) {
        var dx = x, dy = y
        if abs(dy) > 2 * abs(dx) { dx = 0 }
        else if abs(dx) > 2 * abs(dy) { dy = 0 }
        dx = min(max(dx, -16), 16)
        dy = min(max(dy, -16), 16)
        x = 0
        y = 0
        return (dx, dy)
    }
}
