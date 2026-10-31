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

    func testPerProviderConfigurationsPersistAcrossSwitchesAndReloads() throws {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, prototypeDefaults: { nil })

        let openAI = ProviderConfiguration(
            provider: .openAI,
            endpoint: AIProvider.openAI.defaultEndpoint,
            model: ModelPreset.gpt6Luna.model
        )
        let google = ProviderConfiguration(
            provider: .google,
            endpoint: AIProvider.google.defaultEndpoint,
            model: GeminiModelOption.economy.rawValue
        )
        let other = ProviderConfiguration(
            provider: .other,
            endpoint: "https://custom.example.com/v1",
            model: "local-llm"
        )

        try store.saveProviderConfiguration(openAI)
        try store.saveProviderConfiguration(google)
        try store.saveProviderConfiguration(other)

        let reloaded = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        XCTAssertEqual(reloaded.loadProviderConfiguration(), other)
        XCTAssertEqual(reloaded.loadProviderConfiguration(for: .openAI), openAI)
        XCTAssertEqual(reloaded.loadProviderConfiguration(for: .google), google)
        XCTAssertEqual(reloaded.loadProviderConfiguration(for: .other), other)
    }

    func testLegacyConfigurationPreservesPreviousProviderWhenSwitchingToGoogle() throws {
        let defaults = isolatedDefaults()
        let legacyData = #"{"endpoint":"https://legacy.example.com/v1","model":"legacy-model"}"#.data(using: .utf8)!
        defaults.set(legacyData, forKey: "providerConfiguration")

        let store = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        XCTAssertEqual(store.legacyKeyOwnerEndpoint(), "https://legacy.example.com/v1")

        let google = ProviderConfiguration(
            provider: .google,
            endpoint: AIProvider.google.defaultEndpoint,
            model: GeminiModelOption.quality.rawValue
        )
        try store.saveProviderConfiguration(google)

        XCTAssertEqual(store.loadProviderConfiguration(), google)
        XCTAssertEqual(
            store.loadProviderConfiguration(for: .other),
            ProviderConfiguration(provider: .other, endpoint: "https://legacy.example.com/v1", model: "legacy-model")
        )
        XCTAssertEqual(store.legacyKeyOwnerEndpoint(), "https://legacy.example.com/v1")
    }

    func testUsageStatisticsAccumulatePerProviderAndModelPreserveRecordedCostAndReset() throws {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        let introDate = Date(timeIntervalSince1970: 1_798_761_599) // 2026-12-31T23:59:59Z
        let standardDate = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01T00:00:00Z

        // Record Gemini 3.6 Flash usage during introductory pricing period:
        // 1,000,000 input (200,000 cached), 100,000 output -> $0.99
        store.recordUsage(
            TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 200_000, outputTokens: 100_000),
            model: "gemini-3.6-flash",
            provider: .google,
            at: introDate
        )
        // Record Gemini 3.6 Flash usage after standard pricing starts:
        // 1,000,000 input (200,000 cached), 100,000 output -> $1.98
        // Historical introductory cost ($0.99) must not be repriced; total must be $2.97.
        store.recordUsage(
            TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 200_000, outputTokens: 100_000),
            model: "gemini-3.6-flash",
            provider: .google,
            at: standardDate
        )

        // Same model name under .other must be tracked separately and have nil cost.
        store.recordUsage(
            TokenUsage(inputTokens: 500, cachedInputTokens: 0, outputTokens: 100),
            model: "gemini-3.6-flash",
            provider: .other,
            at: standardDate
        )

        let stats = store.loadUsageStatistics()
        XCTAssertEqual(stats.count, 2)

        let googleItem = try XCTUnwrap(stats.first(where: { $0.provider == .google }))
        XCTAssertEqual(googleItem.conversionCount, 2)
        XCTAssertEqual(googleItem.inputTokens, 2_000_000)
        XCTAssertEqual(googleItem.cachedInputTokens, 400_000)
        XCTAssertEqual(googleItem.outputTokens, 200_000)
        XCTAssertEqual(googleItem.unitemizedTokens, 0)
        XCTAssertEqual(googleItem.totalTokens, 2_200_000)
        XCTAssertEqual(googleItem.estimatedCostUSD, Decimal(string: "2.97"))

        let otherItem = try XCTUnwrap(stats.first(where: { $0.provider == .other }))
        XCTAssertEqual(otherItem.conversionCount, 1)
        XCTAssertNil(otherItem.estimatedCostUSD)

        // Unitemized tokens (e.g. unitemized thinking tokens) make cost unknown (nil).
        store.recordUsage(
            TokenUsage(inputTokens: 100, cachedInputTokens: 0, outputTokens: 50, unitemizedTokens: 10),
            model: "gemini-3.6-flash",
            provider: .google,
            at: standardDate
        )
        let afterUnitemized = try XCTUnwrap(store.loadUsageStatistics().first(where: { $0.provider == .google }))
        XCTAssertEqual(afterUnitemized.unitemizedTokens, 10)
        XCTAssertNil(afterUnitemized.estimatedCostUSD)

        let resetDate = Date(timeIntervalSince1970: 1_800_000_000)
        store.resetUsageStatistics(at: resetDate)
        let afterReset = store.loadUsageStatistics()
        XCTAssertEqual(afterReset.count, 2)
        XCTAssertTrue(afterReset.allSatisfy {
            $0.conversionCount == 0 && $0.totalTokens == 0 && $0.collectionStartedAt == resetDate
        })
    }

    func testLegacyUsageStatisticsWithoutProviderMigrateToPreviousProviderBeforeSwitch() throws {
        let defaults = isolatedDefaults()
        let legacyConfig = #"{"endpoint":"https://api.openai.com","model":"gpt-6-sol"}"#.data(using: .utf8)!
        let legacyUsage = #"""
        [{"model":"gpt-6-sol","conversionCount":3,"inputTokens":300,"cachedInputTokens":0,"outputTokens":60}]
        """#.data(using: .utf8)!
        defaults.set(legacyConfig, forKey: "providerConfiguration")
        defaults.set(legacyUsage, forKey: "usageStatistics")

        let store = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        try store.saveProviderConfiguration(ProviderConfiguration(
            provider: .google,
            endpoint: AIProvider.google.defaultEndpoint,
            model: GeminiModelOption.quality.rawValue
        ))

        let stats = store.loadUsageStatistics()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.provider, .openAI)
        XCTAssertEqual(stats.first?.model, "gpt-6-sol")
        XCTAssertEqual(stats.first?.conversionCount, 3)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "org.sumibi.tests.settings.\(UUID().uuidString)"
        domains.append(name)
        return UserDefaults(suiteName: name)!
    }
}
