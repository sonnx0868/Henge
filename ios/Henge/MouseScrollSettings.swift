import SwiftUI

/// Assign input units explicitly: GameController does not identify whether a
/// relative scroll delta came from a pad or a wheel. Remember the user's
/// selection by the name supplied by the device, never infer it from a brand.
struct MouseScrollSettings: View {
    @ObservedObject private var mouse = HardwareMouse.shared
    @AppStorage(HardwareMouse.wheelSpeedKey) private var wheelSpeed = 0.3
    @State private var wheelReady = false

    var body: some View {
        Group {
            ForEach(mouse.scrollDevices) { device in
                Picker(device.name, selection: Binding(
                    get: { mouse.scrollKind(for: device) },
                    set: { mouse.setScrollKind($0, for: device) }
                )) {
                    Text("Trackpad / precise").tag(ScrollInputKind.precision)
                    Text("Mouse wheel").tag(ScrollInputKind.wheel)
                }
            }
            if mouse.scrollDevices.isEmpty {
                Text("Start a Mac with your pointing devices connected to choose each device's scroll type.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Choose Mouse wheel for a notched wheel. Devices reporting the same name share this selection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Mouse wheel speed", value: String(format: "%.1f×", wheelSpeed / 0.3))
            Slider(value: $wheelSpeed, in: 0.1...1.5)
            if !mouse.scrollDevices.isEmpty {
                Text(wheelReady ? "Smooth mouse wheel scrolling is ready." : "Update the Mac helper to enable smooth mouse wheel scrolling.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                wheelReady = henge_vm_pixel_wheel_ready() != 0
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
}
