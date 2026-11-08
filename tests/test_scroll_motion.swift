@main
struct ScrollMotionTests {
    static func main() {
        var motion = ScrollMotion()
        // Includes the -33.3 spike seen on the user's Baseus KeyboardPro.
        let raw: [Float] = [9.06, 3.79, 4.47, 4.05, 3.90, 3.98, 3.98, 14.42,
                            3.75, 4.68, 4.34, 4.82, 4.99, 6.51, 33.32, 7.46, 8.28]
        var total: Float = 0
        for i in stride(from: 0, to: raw.count, by: 2) {
            motion.append(x: 0, y: raw[i])
            if i + 1 < raw.count { motion.append(x: 0, y: raw[i + 1]) }
            let (x, y) = motion.takeFrame()
            precondition(x == 0 && y >= 0 && y <= 16, "per-frame raw budget")
            total += y
        }
        precondition(total > 0 && total <= 144, "a gesture has bounded travel")
        precondition(motion.takeFrame().1 == 0, "no queued movement after the finger stops")
        motion = ScrollMotion()
        motion.append(x: .infinity, y: .nan)
        precondition(motion.takeFrame() == (0, 0), "invalid device values are ignored")
        motion.append(x: -1000000, y: 1000000)
        precondition(motion.takeFrame() == (-16, 16), "large spikes stay bounded before gain")
        motion = ScrollMotion()
        var fine: Float = 0
        for _ in 0..<4 {
            motion.append(x: 0, y: 0.25)
            fine += motion.takeFrame().1
        }
        precondition(fine == 1, "subpixel motion is retained without forcing a wheel step")
        motion = ScrollMotion()
        motion.append(x: 0, y: 4)
        motion.append(x: 0, y: 4)
        precondition(motion.takeFrame() == (0, 8), "identical relative deltas must both count")
        motion.append(x: 1, y: 8)
        precondition(motion.takeFrame() == (0, 8), "vertical gestures suppress sideways noise")
        var wheel = ScrollMotion(kind: .wheel)
        for _ in 0..<5 {
            wheel.append(x: 0, y: 1)
            precondition(wheel.takeFrame() == (0, 32), "each isolated wheel unit gets useful pixel travel")
        }
        precondition(wheel.takeFrame() == (0, 0), "wheel does not leave a motion backlog")
        for _ in 0..<5 { wheel.append(x: 0, y: 1) }
        precondition(wheel.takeFrame() == (0, 160), "five fast notches travel as far as five isolated notches")
        wheel.append(x: -0.125, y: 0)
        precondition(wheel.takeFrame() == (-4, 0), "fractional horizontal wheel units retain direction and precision")
        wheel.append(x: .nan, y: .infinity)
        precondition(wheel.takeFrame() == (0, 0), "invalid wheel values are ignored")
        wheel.append(x: 0, y: -1000000)
        precondition(wheel.takeFrame() == (0, -256), "extreme wheel input is bounded to eight notches before gain")
        motion = ScrollMotion()
        motion.append(x: 0, y: 1)
        wheel.append(x: 0, y: 1)
        precondition(motion.takeFrame() == (0, 1) && wheel.takeFrame() == (0, 32),
                     "separate device accumulators preserve the existing pad conversion")
        for direction: Float in [1, -1] {
            var fallback = ScrollFallback()
            var emitted: Int32 = 0
            for i in 0..<4 {
                emitted += fallback.append(x: 0, y: 32 * direction, kind: .wheel, scale: 0.1, now: Double(i) * 0.2).1
            }
            precondition(emitted != 0 && (emitted > 0) == (direction > 0), "slow isolated wheel input must accumulate at low gain")
        }
        var fallback = ScrollFallback()
        precondition(fallback.append(x: -32, y: 32, kind: .wheel, scale: 0.3, now: 0) == (-1, 1), "default coarse wheel conversion")
        precondition(fallback.append(x: 0, y: 32, kind: .wheel, scale: 1.5, now: 0.01) == (0, 0), "fallback limits event frequency")
        precondition(fallback.append(x: 0, y: 0, kind: .wheel, scale: 1.5, now: 0.06).1 == 1, "bounded pending fallback remains available")
        fallback = ScrollFallback() // helper connection/disconnection, profile switch and reconnect
        precondition(fallback.append(x: 0, y: 0, kind: .wheel, scale: 0.3, now: 1) == (0, 0), "reset clears stale travel")
        precondition(fallback.append(x: 0, y: 4, kind: .precision, scale: 0.3, now: 2).1 == 1, "precision fallback retains its original conversion")
        print("scroll motion: recorded gesture, frame limits, idle, direction, spikes and subpixel checks passed")
        print("wheel motion: five isolated units, fractional horizontal input, invalid values and independent pad state passed")
    }
}
