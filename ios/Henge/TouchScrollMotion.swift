import CoreGraphics

enum ScrollSensitivity {
    static let key = "henge.mouse.scrollSpeed"
    static let defaultValue = 0.3
    static let range = 0.05...1.5
    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : defaultValue
    }
}

struct TwoFingerScroll {
    private var offset = CGPoint.zero

    mutating func apply(combinedMovement: CGPoint, sensitivity: Double) {
        // Adjust the motion common to both fingers. Their separation still
        // changes by the original amount, so pinch and rotate work as before.
        let correction = (CGFloat(ScrollSensitivity.clamped(sensitivity)) - 1) / 2
        offset.x += combinedMovement.x * correction
        offset.y += combinedMovement.y * correction
    }

    func position(for raw: CGPoint) -> CGPoint {
        CGPoint(x: raw.x + offset.x, y: raw.y + offset.y)
    }
}
