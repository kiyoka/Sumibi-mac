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
        // `NSApp`はNSApplicationを一度触るまでnilなので、先に用意する。
        let app = NSApplication.shared
        installMainMenuIfNeeded(in: app)
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
        app.setActivationPolicy(.accessory)
        window?.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }

    /// メインメニューがないと、`⌘V`などの編集コマンドがどこにも届かない。
    /// APIキーのような長い文字列は貼り付けで入れるため、最小限の編集メニューを用意する。
    private func installMainMenuIfNeeded(in app: NSApplication) {
        guard app.mainMenu == nil else { return }

        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sumibi設定を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        mainMenu.addItem(appItem)
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editItem)
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(windowItem)
        windowItem.submenu = windowMenu

        app.mainMenu = mainMenu
    }
}
