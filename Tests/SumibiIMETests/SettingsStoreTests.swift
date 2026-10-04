import XCTest
import SumibiCore
@testable import SumibiIME

final class SettingsStoreTests: XCTestCase {
    private var domains: [String] = []
    override func tearDown() {
        for name in domains { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        domains = []
        super.tearDown()
    }

    func testConfigurationAndDictionarySurviveStoreRecreation() throws {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        let configuration = ProviderConfiguration(endpoint: "https://example.invalid", model: "custom-model")
        try store.saveProviderConfiguration(configuration)
        store.saveUserDictionary("sumibi=炭火")
        let reloaded = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        XCTAssertEqual(reloaded.loadProviderConfiguration(), configuration)
        XCTAssertEqual(reloaded.loadUserDictionary(), "sumibi=炭火")
    }

    func testMissingOrCorruptConfigurationUsesDefaults() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        XCTAssertEqual(store.loadProviderConfiguration(), ProviderConfiguration())
        defaults.set(Data("not-json".utf8), forKey: "providerConfiguration")
        XCTAssertEqual(store.loadProviderConfiguration(), ProviderConfiguration())
        XCTAssertTrue(defaults.bool(forKey: "legacyDefaultModelMigrated"))
    }

    func testLoadNormalizesStoredConfiguration() throws {
        let store = SettingsStore(defaults: isolatedDefaults(), prototypeDefaults: { nil })
        try store.saveProviderConfiguration(ProviderConfiguration(endpoint: " https://example.invalid \n", model: " custom "))
        XCTAssertEqual(store.loadProviderConfiguration(), ProviderConfiguration(endpoint: "https://example.invalid", model: "custom"))
    }

    func testLegacyModelMigratesOnceThenHonorsUserChoice() throws {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        let legacy = ProviderConfiguration(endpoint: "https://example.invalid", model: ProviderConfiguration.legacyDefaultModel)
        try store.saveProviderConfiguration(legacy)
        XCTAssertEqual(store.loadProviderConfiguration().model, ProviderConfiguration.defaultModel)
        XCTAssertTrue(defaults.bool(forKey: "legacyDefaultModelMigrated"))
        try store.saveProviderConfiguration(legacy)
        XCTAssertEqual(store.loadProviderConfiguration(), legacy)
    }

    func testCustomModelIsNotMigrated() throws {
        let store = SettingsStore(defaults: isolatedDefaults(), prototypeDefaults: { nil })
        let custom = ProviderConfiguration(endpoint: "https://example.invalid", model: "chosen-model")
        try store.saveProviderConfiguration(custom)
        XCTAssertEqual(store.loadProviderConfiguration(), custom)
    }

    func testConsentIsEndpointSpecificTrimmedAndRevocable() {
        let store = SettingsStore(defaults: isolatedDefaults(), prototypeDefaults: { nil })
        XCTAssertFalse(store.hasConsent(for: "https://example.invalid"))
        store.saveConsent(for: " https://example.invalid \n")
        XCTAssertTrue(store.hasConsent(for: " https://example.invalid "))
        XCTAssertFalse(store.hasConsent(for: "https://other.invalid"))
        XCTAssertFalse(store.hasConsent(for: " "))
        store.revokeConsent()
        XCTAssertFalse(store.hasConsent(for: "https://example.invalid"))
    }

    func testImportCopiesOnlyKnownSettingsWithoutDeletingSource() throws {
        let legacy = isolatedDefaults()
        let current = isolatedDefaults()
        let configuration = ProviderConfiguration(endpoint: "https://example.invalid", model: "chosen-model")
        let data = try JSONEncoder().encode(configuration)
        legacy.set(data, forKey: "providerConfiguration")
        legacy.set(configuration.endpoint, forKey: "aiDataSharingConsentEndpoint")
        legacy.set(true, forKey: "legacyDefaultModelMigrated")
        legacy.set("fake-sensitive-value", forKey: "apiKey")
        let store = SettingsStore(defaults: current, prototypeDefaults: { legacy })
        store.importPrototypeSettingsIfNeeded()
        XCTAssertEqual(store.loadProviderConfiguration(), configuration)
        XCTAssertTrue(store.hasConsent(for: configuration.endpoint))
        XCTAssertTrue(current.bool(forKey: "legacyDefaultModelMigrated"))
        XCTAssertNil(current.object(forKey: "apiKey"))
        XCTAssertEqual(legacy.data(forKey: "providerConfiguration"), data)
    }

    func testImportNeverOverwritesCurrentConfigurationOrConsent() throws {
        let current = isolatedDefaults()
        let legacy = isolatedDefaults()
        let store = SettingsStore(defaults: current, prototypeDefaults: { legacy })
        let configuration = ProviderConfiguration(endpoint: "https://current.invalid", model: "current")
        try store.saveProviderConfiguration(configuration)
        store.saveConsent(for: configuration.endpoint)
        legacy.set(try JSONEncoder().encode(ProviderConfiguration()), forKey: "providerConfiguration")
        legacy.set("https://old.invalid", forKey: "aiDataSharingConsentEndpoint")
        store.importPrototypeSettingsIfNeeded()
        XCTAssertEqual(store.loadProviderConfiguration(), configuration)
        XCTAssertTrue(store.hasConsent(for: configuration.endpoint))
    }

    func testImportIsNoOpWhenSourceIsMissing() {
        let current = isolatedDefaults()
        let store = SettingsStore(defaults: current, prototypeDefaults: { nil })
        store.importPrototypeSettingsIfNeeded()
        XCTAssertNil(current.object(forKey: "providerConfiguration"))
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "org.sumibi.tests.settings.\(UUID().uuidString)"
        domains.append(name)
        return UserDefaults(suiteName: name)!
    }
}
