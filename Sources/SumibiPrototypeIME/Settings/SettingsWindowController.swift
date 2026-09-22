import AppKit
import SwiftUI

/// 設定ウィンドウを1つだけ持ち、開閉を扱う。
///
/// IMEは`LSUIElement`のアプリなので、そのままではウィンドウを前面に出せない。
/// 開くときに活性化ポリシーを`.accessory`にしてから前面へ出す。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sumibi設定"
            window.contentView = NSHostingView(rootView: APISettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SumibiSettingsWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.accessory)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
