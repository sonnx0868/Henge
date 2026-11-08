import SwiftUI
import UIKit
import GameController

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads are
    /// squarer than 16:9, which would leave bars above and below. Phones are wider, so they stay at 16:9.
    static var fittingScreen: (width: Int, height: Int) {
        guard isPad else { return (1920, 1080) }
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        return mb >= 10_000 ? 8 : mb >= 7_000 ? 6 : 4
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."
}

/// A keyboard attached to the device. iOS reports each key going down and coming up by its HID usage,
/// which is what the Mac's USB keyboard sends, so every key and modifier goes straight across.
enum HardwareKeys {
    static let alternateCommandKey = "henge.keyboard.rightOptionIsCommand"
    private static var routing = HardwareKeyRouting()
    private static var lastKey: CFTimeInterval = 0

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        routing.physical.keys.contains { $0 < 0xe0 } || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            let remap = UserDefaults.standard.bool(forKey: alternateCommandKey)
            for (mapped, pressed) in routing.key(usage, down: down, rightOptionIsCommand: remap) {
                henge_vm_key_hid(mapped, pressed ? 1 : 0)
            }
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if !down {
                if usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
            }
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for usage in routing.releaseAll() { henge_vm_key_hid(usage, 0) }
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { _ in wanted }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
        }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
final class HardwareMouse: ObservableObject {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"
    static let wheelSpeedKey = "henge.mouse.wheelSpeed"

    struct ScrollDevice: Identifiable {
        let id: ObjectIdentifier
        let name: String
        let profileKey: String
        let attachment = UUID()
    }
    @Published private(set) var scrollDevices: [ScrollDevice] = []

    private final class ScrollState {
        var kind: ScrollInputKind
        var motion: ScrollMotion
        var flush: DispatchWorkItem?
        var lastTime: TimeInterval = 0
        var fallback = ScrollFallback()
        var helperReady = false
        var rawLogs = 0, frameLogs = 0
        init(kind: ScrollInputKind) { self.kind = kind; motion = ScrollMotion(kind: kind) }
        deinit { flush?.cancel() }
    }
    private var scrollStates: [ObjectIdentifier: ScrollState] = [:]
    private var inputEpoch: UInt64 = 0

    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttonsDown: Set<Int32> = []
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollDiagnostics = false
    private(set) var recentScrollSamples: [[String: Any]] = []
    private var running = false
    private var secondaryClick = SecondaryClickRouting()
    private var buttonLogs = [0, 0, 0]
    private var uiKitButtonLogs = 0

    func start() {
        guard !running else { return }
        running = true
        inputEpoch &+= 1
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
        scrollDiagnostics = defaults.bool(forKey: "henge.performanceDiagnostics")
        recentScrollSamples.removeAll(keepingCapacity: true)
        secondaryClick.reset()
        buttonLogs = [0, 0, 0]
        uiKitButtonLogs = 0
        let epoch = inputEpoch
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let self, self.running, self.inputEpoch == epoch else { return }
            if let mouse = note.object as? GCMouse { self.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, self.running, self.inputEpoch == epoch,
                  let mouse = note.object as? GCMouse, self.mice.contains(where: { $0 === mouse }) else { return }
            self.releaseButtons()
            self.clearHandlers(mouse)
            let id = ObjectIdentifier(mouse)
            self.scrollStates.removeValue(forKey: id)?.flush?.cancel()
            self.scrollDevices.removeAll { $0.id == id }
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            let locked = (note.object as? UIScene)?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
    }

    func stop() {
        running = false
        inputEpoch &+= 1
        for state in scrollStates.values { state.flush?.cancel() }
        scrollStates.removeAll()
        scrollDevices.removeAll()
        PointerLock.set(false)
        releaseButtons()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            clearHandlers(mouse)
        }
        mice.removeAll()
    }

    private func clearHandlers(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        input.scroll.valueChangedHandler = nil
        input.scroll.xAxis.valueChangedHandler = nil
        input.scroll.yAxis.valueChangedHandler = nil
    }

    func releaseButtons() {
        for button in buttonsDown { henge_vm_mouse_button(button, 0) }
        buttonsDown.removeAll()
        secondaryClick.reset()
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        let name = mouse.vendorName ?? "?"
        let id = ObjectIdentifier(mouse), epoch = inputEpoch
        let profileKey = "henge.mouse.scrollKind." + Data(name.utf8).base64EncodedString()
        let device = ScrollDevice(id: id, name: name == "?" ? "Unnamed pointing device" : name, profileKey: profileKey)
        scrollDevices.append(device)
        scrollStates[id] = ScrollState(kind: scrollKind(for: device))
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.button(0, pressed, device: name) }
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.button(1, pressed, device: name) }
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async { self?.button(2, pressed, device: name) }
        }
        input.scroll.valueChangedHandler = nil
        // Each axis reports its own relative events. Comparing values to the
        // previous callback drops legitimate identical deltas during steady motion.
        input.scroll.xAxis.valueChangedHandler = { [weak self] _, value in
            DispatchQueue.main.async { self?.scrolled(horizontal: 0, vertical: -value, device: device, epoch: epoch) }
        }
        input.scroll.yAxis.valueChangedHandler = { [weak self] _, value in
            DispatchQueue.main.async { self?.scrolled(horizontal: value, vertical: 0, device: device, epoch: epoch) }
        }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    private func moved(_ dx: Float, _ dy: Float) {
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        henge_vm_mouse_move(Int32(x), Int32(y))
    }

    private func button(_ button: Int32, _ pressed: Bool, device: String) {
        guard running, button >= 0, button < 3 else { return }
        if scrollDiagnostics && buttonLogs[Int(button)] < 32 {
            buttonLogs[Int(button)] += 1
            HengeLog.log("input", "mouse button raw: controller \(device) button \(button) \(pressed ? "down" : "up")")
        }
        if button == 1 {
            for down in secondaryClick.controller(pressed: pressed, now: ProcessInfo.processInfo.systemUptime) {
                sendButton(button, down, source: "controller")
            }
        } else {
            sendButton(button, pressed, source: "controller")
        }
    }

    func secondaryClickFromUIKit() {
        guard running else { return }
        let events = secondaryClick.uiKitClick(now: ProcessInfo.processInfo.systemUptime)
        if scrollDiagnostics && uiKitButtonLogs < 32 {
            uiKitButtonLogs += 1
            HengeLog.log("input", "mouse secondary UIKit: \(events.isEmpty ? "duplicate suppressed" : "forwarded")")
        }
        for down in events { sendButton(1, down, source: "UIKit") }
    }

    private func sendButton(_ button: Int32, _ pressed: Bool, source: String) {
        henge_vm_mouse_button(button, pressed ? 1 : 0)
        if scrollDiagnostics && button == 1 {
            HengeLog.log("input", "mouse button guest: \(source) secondary \(pressed ? "down" : "up")")
        }
        if pressed {
            buttonsDown.insert(button)
        } else {
            buttonsDown.remove(button)
            StickyKeys.shared.releaseAll()
        }
    }

    func scrollKind(for device: ScrollDevice) -> ScrollInputKind {
        UserDefaults.standard.string(forKey: device.profileKey).flatMap(ScrollInputKind.init(rawValue:)) ?? .precision
    }

    func setScrollKind(_ kind: ScrollInputKind, for device: ScrollDevice) {
        objectWillChange.send()
        UserDefaults.standard.set(kind.rawValue, forKey: device.profileKey)
        for item in scrollDevices where item.profileKey == device.profileKey {
            scrollStates[item.id]?.flush?.cancel()
            scrollStates[item.id] = ScrollState(kind: kind)
        }
        HengeLog.log("input", "scroll profile: \(device.name) = \(kind.rawValue)")
    }

    /// Each physical device owns its pending frame, gain and fallback state.
    private func scrolled(horizontal: Float, vertical: Float, device: ScrollDevice, epoch: UInt64) {
        guard running, epoch == inputEpoch,
              scrollDevices.contains(where: { $0.id == device.id && $0.attachment == device.attachment }),
              let state = scrollStates[device.id] else { return }
        guard horizontal != 0 || vertical != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - state.lastTime > 0.12 {
            state.motion = ScrollMotion(kind: state.kind)
            if state.kind == .precision { state.fallback = ScrollFallback() }
            state.rawLogs = 0
            state.frameLogs = 0
        }
        state.lastTime = now
        if scrollDiagnostics && horizontal.isFinite && vertical.isFinite {
            recentScrollSamples.append(["uptime": now, "device": device.name, "kind": state.kind.rawValue,
                                        "rawX": horizontal, "rawY": vertical])
            if recentScrollSamples.count > 128 { recentScrollSamples.removeFirst(recentScrollSamples.count - 128) }
        }
        state.motion.append(x: horizontal, y: vertical)
        if scrollDiagnostics && state.rawLogs < 24 {
            state.rawLogs += 1
            HengeLog.log("input", "scroll raw axes: \(horizontal), \(vertical); device \(device.name); kind \(state.kind.rawValue)")
        }
        guard state.flush == nil else { return }
        let work = DispatchWorkItem { [weak self, weak state] in
            guard let self, let state, self.scrollStates[device.id] === state, self.inputEpoch == epoch else { return }
            self.flushScroll(state, device: device)
        }
        state.flush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
    }

    private func flushScroll(_ state: ScrollState, device: ScrollDevice) {
        state.flush = nil
        guard running else { return }
        let defaults = UserDefaults.standard
        let key = state.kind == .wheel ? Self.wheelSpeedKey : Self.scrollSpeedKey
        let configured = defaults.object(forKey: key) == nil ? 0.3 : defaults.double(forKey: key)
        let scale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
        let way: Float = reverse ? -1 : 1
        let (x, y) = state.motion.takeFrame()
        let horizontal = way * x, vertical = way * y
        guard horizontal != 0 || vertical != 0 else { return }
        let helperReady = henge_vm_mouse_scroll_motion(Double(horizontal), Double(vertical), Double(scale)) != 0
        if helperReady != state.helperReady {
            state.fallback = ScrollFallback()
            state.helperReady = helperReady
        }
        if helperReady {
            if scrollDiagnostics && state.frameLogs < 24 {
                state.frameLogs += 1
                HengeLog.log("input", "scroll frame raw: \(horizontal), \(vertical); scale \(scale); device \(device.name); kind \(state.kind.rawValue); protocol v2")
            }
            return
        }
        // Until the helper is ready, never feed a high-rate pad into the guest's
        // accelerated coarse wheel: at most one notch per axis every 50 ms.
        let now = ProcessInfo.processInfo.systemUptime
        let (dx, dy) = state.fallback.append(x: horizontal, y: vertical, kind: state.kind, scale: scale, now: now)
        guard dx != 0 || dy != 0 else { return }
        henge_vm_mouse_scroll(dx, dy)
        if scrollDiagnostics && state.frameLogs < 24 {
            state.frameLogs += 1
            HengeLog.log("input", "scroll frame wheel fallback: \(dx), \(dy); scale \(scale)")
        }
    }
}
