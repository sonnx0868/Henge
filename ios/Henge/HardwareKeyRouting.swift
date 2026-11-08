/// Keep the physical-to-guest mapping chosen at key-down until key-up, even
/// if the preference changes. Multiple physical keys may hold one modifier.
struct HardwareKeyRouting {
    private(set) var physical: [UInt8: UInt8] = [:]

    mutating func key(_ usage: UInt8, down: Bool, rightOptionIsCommand: Bool) -> [(UInt8, Bool)] {
        if down {
            if let mapped = physical[usage] {
                return usage < 0xe0 ? [(mapped, true)] : []
            }
            let mapped: UInt8 = rightOptionIsCommand && usage == 0xe6 ? 0xe3 : usage
            let alreadyDown = physical.values.contains(mapped)
            physical[usage] = mapped
            return alreadyDown ? [] : [(mapped, true)]
        }
        guard let mapped = physical.removeValue(forKey: usage), !physical.values.contains(mapped) else { return [] }
        return [(mapped, false)]
    }

    mutating func releaseAll() -> [UInt8] {
        let keys = Set(physical.values).sorted() // non-modifiers before modifiers
        physical.removeAll()
        return keys
    }
}
