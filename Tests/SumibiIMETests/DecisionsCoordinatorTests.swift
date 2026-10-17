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
