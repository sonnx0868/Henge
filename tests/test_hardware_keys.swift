@main
struct HardwareKeyTests {
    static func main() {
        var keys = HardwareKeyRouting()
        func check(_ events: [(UInt8, Bool)], _ expected: [(UInt8, Bool)]) {
            precondition(events.count == expected.count)
            for (a, b) in zip(events, expected) { precondition(a.0 == b.0 && a.1 == b.1) }
        }
        check(keys.key(0xe6, down: true, rightOptionIsCommand: true), [(0xe3, true)])
        check(keys.key(0x2c, down: true, rightOptionIsCommand: true), [(0x2c, true)])
        check(keys.key(0x2c, down: false, rightOptionIsCommand: true), [(0x2c, false)])
        // The real Command and alternate Command can overlap without releasing
        // the guest modifier until the last physical holder is lifted.
        check(keys.key(0xe3, down: true, rightOptionIsCommand: true), [])
        check(keys.key(0xe6, down: false, rightOptionIsCommand: false), [])
        check(keys.key(0xe3, down: false, rightOptionIsCommand: false), [(0xe3, false)])
        check(keys.key(0xe6, down: true, rightOptionIsCommand: false), [(0xe6, true)])
        check(keys.key(0xe6, down: false, rightOptionIsCommand: true), [(0xe6, false)])
        check(keys.key(0xe2, down: true, rightOptionIsCommand: true), [(0xe2, true)]) // left Option
        check(keys.key(0xe2, down: true, rightOptionIsCommand: true), []) // modifier repeat
        check(keys.key(0x04, down: true, rightOptionIsCommand: true), [(0x04, true)])
        check(keys.key(0x04, down: true, rightOptionIsCommand: true), [(0x04, true)]) // text repeat
        check(keys.key(0xe6, down: true, rightOptionIsCommand: true), [(0xe3, true)])
        precondition(keys.releaseAll() == [0x04, 0xe2, 0xe3])
        precondition(keys.physical.isEmpty && keys.releaseAll().isEmpty)
        check(keys.key(0xe6, down: false, rightOptionIsCommand: true), [])
        print("hardware keys: alternate Command, overlapping modifiers, preference changes, repeats and focus-loss release passed")
    }
}
