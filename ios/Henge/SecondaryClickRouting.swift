/// UIKit and GameController may describe the same physical secondary click.
/// Retain complete down/up pairs while suppressing duplicates across the two APIs.
struct SecondaryClickRouting {
    enum UIKitSource: String { case tap, contextMenu }
    private(set) var held = false
    private var suppressControllerPair = false
    private var lastController = -Double.infinity
    private var lastUIKit = -Double.infinity
    private var lastUIKitSource: UIKitSource?
    private let overlap = 0.12

    mutating func controller(pressed: Bool, now: Double) -> [Bool] {
        if pressed {
            guard !held else { return [] }
            if now - lastUIKit < overlap {
                suppressControllerPair = true
                return []
            }
            suppressControllerPair = false
            held = true
            lastController = now
            return [true]
        }
        if suppressControllerPair {
            suppressControllerPair = false
            return []
        }
        guard held else { return [] }
        held = false
        lastController = now
        return [false]
    }

    mutating func uiKitClick(now: Double, source: UIKitSource = .tap) -> [Bool] {
        guard !held, now - lastController >= overlap else { return [] }
        if lastUIKitSource != source && now - lastUIKit < overlap { return [] }
        lastUIKit = now
        lastUIKitSource = source
        return [true, false]
    }

    mutating func reset() { self = SecondaryClickRouting() }
}
