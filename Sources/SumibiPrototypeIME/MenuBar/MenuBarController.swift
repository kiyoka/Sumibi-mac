import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "dev.kiyoka.inputmethod.SumibiPrototypeProbe1", category: "menubar")

/// メニューバーに常時表示するSumibiアイコンと、その下に出すメニュー。
///
/// IMEと同じプロセスに置く。入力ソースとしてSumibiが選ばれていなくても、プロセスが動いていれば
/// アイコンは出続ける。ログイン直後はIMEが一度も選ばれずプロセスが起動しないため、
/// このアプリ自身をログイン項目へ登録し、ログイン時に起動させる。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    /// 利用者がメニューからログイン時の起動を切ったことを覚えておく。切った後に自動で登録し直さないため。
    private static let loginItemOptOutKey = "MenuBarLoginItemOptOut"

    private var statusItem: NSStatusItem?
    private let loginItemMenuItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        item.button?.toolTip = "Sumibi"
        item.button?.setAccessibilityLabel("Sumibi")

        let menu = NSMenu()
        menu.delegate = self
        let settings = menu.addItem(withTitle: "Sumibi設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)
        item.menu = menu
        statusItem = item

        registerLoginItemIfNeeded()
    }

    /// 橙地に黒線のiOS版アイコンから線画だけを取り出したテンプレート画像。
    /// テンプレートにしておけば、明るいメニューバーでは黒、暗いメニューバーでは白で描かれる。
    private static func icon() -> NSImage? {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else {
            log.error("MenuBarIcon is missing from the bundle")
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItemMenuItem.state = .on
            loginItemMenuItem.title = "ログイン時に起動"
        case .requiresApproval:
            loginItemMenuItem.state = .off
            loginItemMenuItem.title = "ログイン時に起動(システム設定で許可が必要)"
        default:
            loginItemMenuItem.state = .off
            loginItemMenuItem.title = "ログイン時に起動"
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                UserDefaults.standard.set(true, forKey: Self.loginItemOptOutKey)
            case .requiresApproval:
                // システム設定で利用者が切った状態。アプリ側からは有効にできないので、設定画面を開く。
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                UserDefaults.standard.set(false, forKey: Self.loginItemOptOutKey)
            }
        } catch {
            log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        log.notice("login item status=\(service.status.rawValue, privacy: .public)")
    }

    /// 初回はログイン項目へ登録する。利用者がメニューやシステム設定で切った場合は登録し直さない。
    private func registerLoginItemIfNeeded() {
        let service = SMAppService.mainApp
        // 一度も登録していないアプリでも`.notFound`が返ることがあるため、登録済み以外は登録を試す。
        guard service.status == .notRegistered || service.status == .notFound,
              !UserDefaults.standard.bool(forKey: Self.loginItemOptOutKey) else {
            log.notice("login item status=\(service.status.rawValue, privacy: .public)")
            return
        }
        do {
            try service.register()
        } catch {
            log.error("login item register failed: \(String(describing: error), privacy: .public)")
        }
        log.notice("login item registered status=\(service.status.rawValue, privacy: .public)")
    }
}
