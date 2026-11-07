@main
struct ScrollMotionTests {
    static func main() {
        var motion = ScrollMotion()
        // Includes the -33.3 spike seen on the user's Baseus KeyboardPro.
        let raw: [Float] = [9.06, 3.79, 4.47, 4.05, 3.90, 3.98, 3.98, 14.42,
                            3.75, 4.68, 4.34, 4.82, 4.99, 6.51, 33.32, 7.46, 8.28]
        var total: Int32 = 0
        for i in stride(from: 0, to: raw.count, by: 2) {
            motion.append(x: 0, y: raw[i])
            if i + 1 < raw.count { motion.append(x: 0, y: raw[i + 1]) }
            let (x, y) = motion.takePixels(scale: 0.1)
            precondition(x == 0 && y >= 0 && y <= 5, "per-frame pixel budget at minimum speed")
            total += y
        }
        precondition(total > 0 && total <= 45, "a gesture has bounded travel")
        precondition(motion.takePixels(scale: 0.1).1 == 0, "no queued movement after the finger stops")
        motion = ScrollMotion()
        motion.append(x: .infinity, y: .nan)
        precondition(motion.takePixels(scale: 0.3) == (0, 0), "invalid device values are ignored")
        motion.append(x: -1000000, y: 1000000)
        precondition(motion.takePixels(scale: 0.3) == (-16, 16), "large spikes cannot cross a page in one frame")
        motion = ScrollMotion()
        var fine: Int32 = 0
        for _ in 0..<4 {
            motion.append(x: 0, y: 0.25)
            fine += motion.takePixels(scale: 0.3).1
        }
        precondition(fine == 1, "subpixel motion is retained without forcing a wheel step")
        print("scroll motion: recorded gesture, frame limits, idle, direction, spikes and subpixel checks passed")
    }
}
