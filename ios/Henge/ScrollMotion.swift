/// High-resolution pad motion stays in pixels. Each display interval has a bounded
/// budget; old motion is discarded rather than replayed after the finger stops.
struct ScrollMotion {
    private var x: Float = 0, y: Float = 0
    private var restX: Float = 0, restY: Float = 0

    mutating func append(x dx: Float, y dy: Float) {
        if dx.isFinite { x += min(max(dx, -64), 64) }
        if dy.isFinite { y += min(max(dy, -64), 64) }
    }

    mutating func takePixels(scale: Float) -> (Int32, Int32) {
        let safeScale = scale.isFinite ? min(max(scale, 0.1), 1.5) : 0.3
        let gain = safeScale / 0.3, limit = max(2, 16 * gain)
        let dx = min(max(x * gain + restX, -limit), limit)
        let dy = min(max(y * gain + restY, -limit), limit)
        let wholeX = Int32(dx.rounded(.towardZero)), wholeY = Int32(dy.rounded(.towardZero))
        restX = dx - Float(wholeX)
        restY = dy - Float(wholeY)
        x = 0
        y = 0
        return (wholeX, wholeY)
    }
}
