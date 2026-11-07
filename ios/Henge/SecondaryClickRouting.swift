/// UIKit and GameController may describe the same physical secondary click.
/// Retain complete down/up pairs while suppressing duplicates across the two APIs.
struct SecondaryClickRouting {
    private(set) var held = false
    private var suppressControllerPair = false
    private var lastController = -Double.infinity
    private var lastUIKit = -Double.infinity
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

    mutating func uiKitClick(now: Double) -> [Bool] {
        guard !held, now - lastController >= overlap else { return [] }
        lastUIKit = now
        return [true, false]
    }

    mutating func reset() { self = SecondaryClickRouting() }
}
