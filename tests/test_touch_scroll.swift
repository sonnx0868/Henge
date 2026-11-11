import CoreGraphics

@main struct TouchScrollTests {
    static func main() {
        let a = CGPoint(x: 100, y: 150), b = CGPoint(x: 200, y: 250)
        for gain in [0.05, 0.3, 1, 1.5] {
            var scroll = TwoFingerScroll()
            scroll.apply(combinedMovement: CGPoint(x: 20, y: 40), sensitivity: gain)
            let aa = scroll.position(for: CGPoint(x: a.x + 10, y: a.y + 20))
            let bb = scroll.position(for: CGPoint(x: b.x + 10, y: b.y + 20))
            precondition(abs((aa.x + bb.x) / 2 - 150 - 10 * gain) < 0.001)
            precondition(abs((aa.y + bb.y) / 2 - 200 - 20 * gain) < 0.001)
            precondition(bb.x - aa.x == b.x - a.x && bb.y - aa.y == b.y - a.y)
        }
        var pinch = TwoFingerScroll()
        pinch.apply(combinedMovement: .zero, sensitivity: 0.3)
        precondition(pinch.position(for: a) == a && pinch.position(for: b) == b)
        precondition(ScrollSensitivity.clamped(.nan) == 0.3)
        print("PASS: touch scroll gain preserves pinch separation and rotation")
    }
}
