import AppKit
import InputMethodKit

@main
enum PrototypeMain {
    static func main() {
        // 開発用: 入力メソッドとして動かさず、設定ウィンドウだけを開く。画面の確認に使う。
        if CommandLine.arguments.contains("--settings") {
            MainActor.assumeIsolated { SettingsWindowController.shared.show() }
            NSApplication.shared.run()
            return
        }

        guard let identifier = Bundle.main.bundleIdentifier,
              let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
              let server = IMKServer(name: connection, bundleIdentifier: identifier) else {
            fatalError("The prototype must run from its input-method app bundle")
        }
        withExtendedLifetime(server) {
            NSApplication.shared.run()
        }
    }
}
