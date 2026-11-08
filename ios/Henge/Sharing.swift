import SwiftUI
import UIKit

/// What a running Mac shares with this device: the Shared folder in Files, and the clipboard. The Mac mounts
/// the folder and follows the clipboard through a small helper (host/share.c, tools/henge-agent.m).
enum Sharing {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4/.henge/install | sh"

    /// Before a Mac starts.
    static func prepare() {
        henge_vm_set_native_images(UserDefaults.standard.object(forKey: "henge.nativeImages") as? Bool == false ? 0 : 1)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(folder.path, socket, Bundle.main.path(forResource: "henge-agent", ofType: "gz"))
        // Do not present a previous session's measurements as current.
        try? FileManager.default.removeItem(at: diagnosticsURL)
    }

    private static var diagnosticsURL: URL { folder.appendingPathComponent(".henge-diagnostics.json") }

    /// Opt-in measurements only, readable inside this Mac through its existing
    /// shared folder. No key presses, clipboard contents, URLs or account data.
    @MainActor static func writeDiagnostics(_ metrics: [String: Any]) {
        guard UserDefaults.standard.bool(forKey: "henge.performanceDiagnostics"),
              let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]) else { return }
        try? data.write(to: diagnosticsURL, options: .atomic)
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = henge_share_agent_seen()
        return seen >= 0 && seen < 40
    }

    /// What is copied on the Mac is copied here too. The other way needs the system's paste button: iOS
    /// asks for permission whenever an app reads the clipboard on its own.
    static func followMacClipboard() async {
        while !Task.isCancelled {
            if let text = henge_share_take_clipboard() {
                UIPasteboard.general.string = String(cString: text)
                free(text)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Text from this device, pasted at the Mac's cursor. Without the helper it is typed, as far as the keyboard can.
    static func paste(_ text: String) {
        Task { @MainActor in
            if helperRunning {
                henge_share_set_clipboard(text)
                try? await Task.sleep(nanoseconds: 800_000_000) // for the helper to put it on the Mac's clipboard
                Keys.chord(Keys.command, "v")
            } else {
                await Keys.typeSlowly(text)
            }
        }
    }

    /// Types the set up command at the Mac's cursor, and stops there: the person using the Mac presses Return.
    /// Henge can't see what has the keyboard, so it must not submit anything by itself. Opening Terminal for them
    /// through Spotlight was tried: when Spotlight was slow the text went to a web search, and it could as easily
    /// have gone to a chat.
    static func typeSetUpCommand() async {
        await Keys.typeSlowly(setUpCommand)
    }
}
