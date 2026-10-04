import AppKit
import InputMethodKit

@main
enum SumibiMain {
    static func main() {
        SettingsStore().importPrototypeSettingsIfNeeded()
        // 開発用: 入力メソッドとして動かさず、設定ウィンドウだけを開く。画面の確認に使う。
        #if SUMIBI_DEVELOPMENT
        if CommandLine.arguments.contains("--settings") {
            MainActor.assumeIsolated { SettingsWindowController.shared.show() }
            NSApplication.shared.run()
            return
        }
        #endif

        guard let identifier = Bundle.main.bundleIdentifier,
              let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
              let server = IMKServer(name: connection, bundleIdentifier: identifier) else {
            fatalError("Sumibi must run from its input-method app bundle")
        }
        withExtendedLifetime(server) {
            // `NSApp`はNSApplicationを一度触るまでnilなので、メニューバーより先に用意する。
            let app = NSApplication.shared
            MainActor.assumeIsolated { MenuBarController.shared.install() }
            app.run()
        }
    }
}
