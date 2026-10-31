import XCTest
import Security
import SumibiCore
@testable import SumibiIME

final class DecisionsCoordinatorTests: XCTestCase {
    private var domains: [String] = []
    override func tearDown() {
        for domain in domains { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        domains = []
        super.tearDown()
    }
    private func make() throws -> DecisionsAuthorizationFixture {
        let domain = "org.sumibi.tests.decisions-auth.\(UUID().uuidString)"
        domains.append(domain)
        return try DecisionsAuthorizationFixture(defaults: UserDefaults(suiteName: domain)!)
    }

    func testDisabledOrNoOpenAIConsentCannotReadKeysOrCreateClients() throws {
        for consent in [false, true] {
            let f = try make()
            var settings = f.store.load()
            settings.enabled = false
            settings.consent = consent
            try f.store.save(settings)
            XCTAssertThrowsError(try f.coordinator().prepare(observation: f.observation, settings: settings))
            XCTAssertTrue(f.decisionsKeys.calls.isEmpty)
            XCTAssertTrue(f.manualKeys.calls.isEmpty)
        }
    }

    func testMissingManualKeyOrManualConsentPreventsPaidDecisionsCall() throws {
        for missingKey in [false, true] {
            let f = try make()
            if missingKey { f.manualKeys.loadResult = (errSecItemNotFound, nil) }
            else { f.manual.revokeConsent() }
            XCTAssertThrowsError(try f.coordinator().prepare(observation: f.observation, settings: f.store.load()))
            XCTAssertTrue(f.decisionsKeys.calls.isEmpty)
            XCTAssertEqual(f.store.calls, 0)
        }
    }

    func testMissingDecisionsKeyDoesNotChangeManualKeyOrReserveCalls() throws {
        let f = try make()
        f.decisionsKeys.loadResult = (errSecItemNotFound, nil)
        XCTAssertThrowsError(try f.coordinator().prepare(observation: f.observation, settings: f.store.load())) {
            XCTAssertEqual($0 as? DecisionsError, .missingKey)
        }
        XCTAssertEqual(f.manualKeys.calls, ["load"])
        XCTAssertEqual(f.store.calls, 0)
    }

    func testProviderOrDictionaryChangesAndKeyRevisionInvalidateWork() throws {
        for scenario in 0..<3 {
            let f = try make()
            let work = try f.coordinator().prepare(observation: f.observation, settings: f.store.load())
            XCTAssertTrue(work.remainsAuthorized())
            if scenario == 0 { f.store.touchRevision() }
            if scenario == 1 {
                try f.manual.saveProviderConfiguration(ProviderConfiguration(endpoint: "https://changed.invalid", model: "different"))
            }
            if scenario == 2 { f.defaults.set("changed", forKey: "userDictionary") }
            XCTAssertFalse(work.remainsAuthorized())
        }
    }

    func testOverLimitRejectsBeforeKeychainAndDoesNotReserve() throws {
        let f = try make()
        f.defaults.set(String(repeating: "x", count: 1_001), forKey: "userDictionary")
        XCTAssertThrowsError(try f.coordinator().prepare(observation: f.observation, settings: f.store.load()))
        XCTAssertTrue(f.manualKeys.calls.isEmpty)
        XCTAssertTrue(f.decisionsKeys.calls.isEmpty)
        XCTAssertEqual(f.store.calls, 0)
    }

    func testCustomProvidersAreRejectedBeforeAnyKeyRead() throws {
        for endpoint in ["http://api.openai.com", "https://api.openai.com.evil.invalid", "https://other.invalid",
            "https://api.openai.com:444", "https://user:password@api.openai.com", "https://api.openai.com/proxy", "https://api.openai.com?redirect=x"] {
            let f = try make()
            try f.manual.saveProviderConfiguration(.init(endpoint: endpoint, model: "dummy"))
            f.manual.saveConsent(for: endpoint)
            XCTAssertThrowsError(try f.coordinator().prepare(observation: f.observation, settings: f.store.load())) {
                XCTAssertEqual($0 as? DecisionsError, .unsupportedProvider)
            }
            XCTAssertTrue(f.decisionsKeys.calls.isEmpty); XCTAssertTrue(f.manualKeys.calls.isEmpty)
            XCTAssertEqual(f.store.calls, 0)
        }
        for endpoint in ["https://api.openai.com", "https://api.openai.com/v1", "https://api.openai.com:443/v1/"] {
            XCTAssertTrue(DecisionsCoordinator.isOfficialOpenAI(endpoint))
        }
        for endpoint in [
            "https://generativelanguage.googleapis.com/v1beta/openai",
            "https://generativelanguage.googleapis.com:443/v1beta/openai/"
        ] {
            XCTAssertTrue(DecisionsCoordinator.isOfficialGoogle(endpoint))
        }
        for endpoint in [
            "http://generativelanguage.googleapis.com/v1beta/openai",
            "https://generativelanguage.googleapis.com/v1beta",
            "https://generativelanguage.googleapis.com.evil.invalid/v1beta/openai",
            "https://generativelanguage.googleapis.com:444/v1beta/openai",
            "https://generativelanguage.googleapis.com/v1beta/openai?redirect=x"
        ] {
            XCTAssertFalse(DecisionsCoordinator.isOfficialGoogle(endpoint))
        }
        // Even if the URL matches OpenAI or Google, .other provider is rejected.
        for endpoint in [AIProvider.openAI.defaultEndpoint, AIProvider.google.defaultEndpoint, "https://custom.example.com/v1"] {
            let f = try make()
            try f.manual.saveProviderConfiguration(.init(endpoint: endpoint, model: "dummy", provider: .other))
            f.manual.saveConsent(for: endpoint)
            XCTAssertThrowsError(try f.coordinator().prepare(observation: f.observation, settings: f.store.load())) {
                XCTAssertEqual($0 as? DecisionsError, .unsupportedProvider)
            }
            XCTAssertTrue(f.decisionsKeys.calls.isEmpty)
            XCTAssertTrue(f.manualKeys.calls.isEmpty)
        }
    }

    func testSwitchingToGoogleInvalidatesPreparedWorkAndRequiresReconsentBeforeReadingAnyKey() throws {
        let f = try make()
        let work = try f.coordinator().prepare(observation: f.observation, settings: f.store.load())
        XCTAssertTrue(work.remainsAuthorized())

        // Reset recorded key calls and switch to Google while Decisions settings were consented for OpenAI.
        f.decisionsKeys.calls = []
        f.manualKeys.calls = []
        let google = ProviderConfiguration(
            provider: .google,
            endpoint: AIProvider.google.defaultEndpoint,
            model: GeminiModelOption.quality.rawValue
        )
        try f.manual.saveProviderConfiguration(google)
        f.manual.saveConsent(for: google.endpoint)

        // Previously prepared work is immediately invalidated.
        XCTAssertFalse(work.remainsAuthorized())

        // Without re-consenting to Decisions for the new Google conversion endpoint, prepare fails before reading keys.
        XCTAssertThrowsError(try f.coordinator().prepare(observation: f.observation, settings: f.store.load())) {
            XCTAssertEqual($0 as? DecisionsError, .invalidSettings)
        }
        XCTAssertTrue(f.decisionsKeys.calls.isEmpty)
        XCTAssertTrue(f.manualKeys.calls.isEmpty)
        XCTAssertEqual(f.store.calls, 0)
    }

    func testGoogleProviderUsesOpenAIKeyForDecisionsAndGoogleKeyForConversionWithoutCrossingKeys() async throws {
        let f = try make()
        let google = ProviderConfiguration(
            provider: .google,
            endpoint: AIProvider.google.defaultEndpoint,
            model: GeminiModelOption.quality.rawValue
        )
        try f.manual.saveProviderConfiguration(google)
        f.manual.saveConsent(for: google.endpoint)
        try f.store.save(f.store.load(), conversionEndpoint: google.endpoint)

        let sharedKeychain = RecordingKeychain(storage: [
            "endpoint:https://api.openai.com": Data("sk-openai-decisions-key".utf8),
            "endpoint:https://generativelanguage.googleapis.com/v1beta/openai": Data("AIzaSy-google-conversion-key".utf8)
        ])
        var capturedDecisionsKey: String?
        var capturedConversionConfig: OpenAICompatibleConfiguration?
        let conversion = ConversionCoordinator(
            settings: f.manual,
            keys: APIKeyStore(keychain: sharedKeychain),
            responseMode: { "api" },
            makeClient: { config in
                capturedConversionConfig = config
                return f.converter
            }
        )
        let coordinator = DecisionsCoordinator(
            store: f.store,
            manualSettings: f.manual,
            keys: APIKeyStore(keychain: sharedKeychain),
            conversion: conversion,
            makeDecisions: { key, _ in
                capturedDecisionsKey = key
                return FixedDecisionsScore()
            }
        )

        let work = try coordinator.prepare(observation: f.observation, settings: f.store.load())
        XCTAssertEqual(capturedDecisionsKey, "sk-openai-decisions-key")
        XCTAssertEqual(capturedConversionConfig?.endpoint, URL(string: google.endpoint))
        XCTAssertEqual(capturedConversionConfig?.model, google.model)
        XCTAssertEqual(capturedConversionConfig?.apiKey, "AIzaSy-google-conversion-key")

        let score = try await work.score(f.observation)
        XCTAssertEqual(score, 0.9)
        let converted = await work.convert()
        XCTAssertEqual(converted, Result<ConversionResult, ConversionError>.success(ConversionResult(candidates: ["日本語"])))

        // If OpenAI key is missing while Google key exists, prepare fails with .missingKey.
        sharedKeychain.storage?["endpoint:https://api.openai.com"] = nil
        XCTAssertThrowsError(try coordinator.prepare(observation: f.observation, settings: f.store.load())) {
            XCTAssertEqual($0 as? DecisionsError, .missingKey)
        }

        // If Google key is missing, prepare fails before reading the OpenAI key.
        sharedKeychain.storage?["endpoint:https://api.openai.com"] = Data("sk-openai-decisions-key".utf8)
        sharedKeychain.storage?["endpoint:https://generativelanguage.googleapis.com/v1beta/openai"] = nil
        sharedKeychain.queries = []
        XCTAssertThrowsError(try coordinator.prepare(observation: f.observation, settings: f.store.load())) {
            XCTAssertEqual($0 as? ConversionError, .apiKeyMissing)
        }
        let queriedAccounts = sharedKeychain.queries.compactMap { $0[kSecAttrAccount as String] as? String }
        XCTAssertFalse(queriedAccounts.contains("endpoint:https://api.openai.com"))
    }

    func testPreparedConversionUsesExistingProviderAndStripsTriggerPunctuation() async throws {
        let f = try make()
        let work = try f.coordinator().prepare(observation: f.observation, settings: f.store.load())
        let score = try await work.score(f.observation)
        XCTAssertEqual(score, 0.9)
        let converted = await work.convert()
        XCTAssertEqual(converted, .success(ConversionResult(candidates: ["日本語"])))
        let requests = await f.converter.requests
        XCTAssertEqual(requests, [ConversionRequest(source: "nihongo")])
        XCTAssertEqual(f.store.calls, 0) // Only the lifecycle reserves a paid send.
    }
}

private final class DecisionsAuthorizationFixture {
    let defaults: UserDefaults
    let store: DecisionsSettingsStore
    let manual: SettingsStore
    let decisionsKeys = RecordingKeychain()
    let manualKeys = RecordingKeychain()
    let converter = RecordingAmbientConverter()
    let observation = DecisionsObservation(text: "nihongo? ", latestKey: "?")!
    init(defaults: UserDefaults) throws {
        self.defaults = defaults
        store = DecisionsSettingsStore(defaults: defaults)
        manual = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        var settings = DecisionsSettings()
        settings.enabled = true
        settings.consent = true
        try store.save(settings)
        manual.saveConsent(for: ProviderConfiguration.defaultEndpoint)
        decisionsKeys.loadResult = (errSecSuccess, Data("fake-decisions-key".utf8) as CFData)
        manualKeys.loadResult = (errSecSuccess, Data("fake-manual-key".utf8) as CFData)
    }
    func coordinator() -> DecisionsCoordinator {
        let conversion = ConversionCoordinator(settings: manual, keys: APIKeyStore(keychain: manualKeys),
            responseMode: { "api" }, makeClient: { _ in self.converter })
        return DecisionsCoordinator(store: store, manualSettings: manual,
            keys: APIKeyStore(keychain: decisionsKeys),
            conversion: conversion, makeDecisions: { _, _ in FixedDecisionsScore() })
    }
}

private struct FixedDecisionsScore: DecisionsService {
    func score(_ observation: DecisionsObservation) async throws -> Double { 0.9 }
    func scores(_ observations: [DecisionsObservation]) async throws -> [DecisionsAnswer] {
        observations.map { _ in .probability(0.9) }
    }
}
private actor RecordingAmbientConverter: ConversionService {
    var requests: [ConversionRequest] = []
    func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        requests.append(request)
        return ConversionResult(candidates: ["日本語"])
    }
}
