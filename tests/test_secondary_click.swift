@main
struct SecondaryClickTests {
    static func main() {
        var route = SecondaryClickRouting()
        precondition(route.controller(pressed: true, now: 1) == [true])
        precondition(route.controller(pressed: false, now: 1.02) == [false])
        precondition(route.uiKitClick(now: 1.03).isEmpty, "UIKit must not duplicate a controller click")
        precondition(route.controller(pressed: true, now: 1.05) == [true], "same-source rapid clicks stay valid")
        precondition(route.uiKitClick(now: 2).isEmpty, "a held controller button cannot be released by a UIKit tap")
        precondition(route.controller(pressed: false, now: 2.01) == [false])
        route.reset()
        precondition(route.uiKitClick(now: 3) == [true, false], "UIKit alone produces a complete click")
        precondition(route.controller(pressed: true, now: 3.01).isEmpty)
        precondition(route.controller(pressed: false, now: 3.02).isEmpty, "late controller pair is fully suppressed")
        precondition(route.uiKitClick(now: 3.05) == [true, false], "same-source UIKit clicks are not throttled")
        precondition(!route.held)
        precondition(route.controller(pressed: false, now: 4).isEmpty, "stray release is ignored")
        precondition(route.controller(pressed: true, now: 4.1) == [true])
        route.reset()
        precondition(!route.held && route.uiKitClick(now: 4.11) == [true, false], "reset clears stale held state")
        route.reset()
        precondition(route.uiKitClick(now: 5, source: .contextMenu) == [true, false], "a menu request alone forwards a secondary click")
        precondition(route.uiKitClick(now: 5.02, source: .tap).isEmpty, "tap and menu callbacks must not double the same click")
        precondition(route.uiKitClick(now: 5.05, source: .contextMenu) == [true, false], "rapid clicks through the same UIKit route stay valid")
        precondition(route.controller(pressed: true, now: 5.06).isEmpty)
        precondition(route.controller(pressed: false, now: 5.07).isEmpty)
        print("secondary click: controller/UIKit delivery, duplicate ordering, holds, rapid clicks and reset passed")
    }
}
