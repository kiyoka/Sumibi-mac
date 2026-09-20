import AppKit
import InputMethodKit

@main
enum PrototypeMain {
    static func main() {
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
