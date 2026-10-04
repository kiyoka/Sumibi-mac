import XCTest
import SumibiCore
@testable import SumibiIME

final class DevelopmentOptionsTests: XCTestCase {
    private var domains: [String] = []

    override func tearDown() {
        for domain in domains { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        domains = []
        super.tearDown()
    }

    func testEmptyPreferencesAlwaysUseSafeDefaults() {
        let options = DevelopmentOptions(defaults: defaults())
        XCTAssertEqual(options.responseMode, "api")
        XCTAssertFalse(options.diagnoseText)
        XCTAssertEqual(options.pokeStyle, "marked")
    }

    func testStaleExperimentalPreferencesAreIgnoredInProduction() {
        let defaults = defaults()
        defaults.set("success", forKey: "PrototypeResponseMode")
        defaults.set(true, forKey: "PrototypeDiagnoseText")
        defaults.set("insert", forKey: "PrototypePokeStyle")
        let options = DevelopmentOptions(defaults: defaults)
        XCTAssertEqual(options.responseMode, DevelopmentOptions.isEnabled ? "success" : "api")
        XCTAssertEqual(options.diagnoseText, DevelopmentOptions.isEnabled)
        XCTAssertEqual(options.pokeStyle, DevelopmentOptions.isEnabled ? "insert" : "marked")
    }

    func testUnknownExperimentalValuesFallBackToProductionBehavior() {
        let defaults = defaults()
        defaults.set("typo", forKey: "PrototypeResponseMode")
        defaults.set("typo", forKey: "PrototypePokeStyle")
        let options = DevelopmentOptions(defaults: defaults)
        XCTAssertEqual(options.responseMode, "api")
        XCTAssertEqual(options.pokeStyle, "marked")
    }

    func testEveryMockModeRequiresAnOptedInBuild() {
        for mode in ["success", "slow", "failure", "timeout"] {
            XCTAssertEqual(DevelopmentOptions.responseMode(mode), DevelopmentOptions.isEnabled ? mode : "api")
        }
    }

    func testInjectedMockModeCannotBypassKeyAndConsentInProduction() async throws {
        let keys = RecordingKeychain()
        let settings = SettingsStore(defaults: defaults(), prototypeDefaults: { nil })
        let coordinator = ConversionCoordinator(settings: settings, keys: APIKeyStore(keychain: keys), responseMode: { "success" }) { _ in
            XCTFail("No real or fake network client should be created without a key")
            return NeverUsedService()
        }
        if DevelopmentOptions.isEnabled {
            let result = try await coordinator.service().convert(ConversionRequest(source: "ohayou"))
            XCTAssertEqual(result.candidates, ["おはよう"])
            XCTAssertTrue(keys.calls.isEmpty)
        } else {
            XCTAssertThrowsError(try coordinator.service()) { XCTAssertEqual($0 as? ConversionError, .apiKeyMissing) }
            XCTAssertEqual(keys.calls, ["load"])
        }
    }

    func testInputSourceAndControllerRegistrationNamesRemainCompatible() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("App/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "org.sumibi.inputmethod.Sumibi")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Sumibi")
        XCTAssertEqual(plist["InputMethodConnectionName"] as? String, "org.sumibi.inputmethod.Sumibi_Connection")
        let className = try XCTUnwrap(plist["InputMethodServerControllerClass"] as? String)
        XCTAssertEqual(className, "SumibiPrototypeInputController")
        let registeredClass = try XCTUnwrap(NSClassFromString(className))
        XCTAssertEqual(ObjectIdentifier(registeredClass), ObjectIdentifier(SumibiInputController.self))
        let modes = try XCTUnwrap(plist["ComponentInputModeDict"] as? [String: Any])
        let list = try XCTUnwrap(modes["tsInputModeListKey"] as? [String: Any])
        let japanese = try XCTUnwrap(list["com.apple.inputmethod.Japanese"] as? [String: Any])
        XCTAssertEqual(japanese["TISInputSourceID"] as? String, "org.sumibi.inputmethod.Sumibi.Japanese")
    }

    private func defaults() -> UserDefaults {
        let domain = "org.sumibi.tests.development.\(UUID().uuidString)"
        domains.append(domain)
        return UserDefaults(suiteName: domain)!
    }
}

private struct NeverUsedService: ConversionService {
    func convert(_ request: ConversionRequest) async throws -> ConversionResult { fatalError("Must not be called") }
}
