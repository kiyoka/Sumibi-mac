import XCTest
import Security
import SumibiCore
@testable import SumibiIME

final class DecisionsSettingsStoreTests: XCTestCase {
    private func isolated(_ body: (UserDefaults, DecisionsSettingsStore) throws -> Void) throws {
        let domain = "org.sumibi.tests.decisions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults, DecisionsSettingsStore(defaults: defaults))
    }

    func testDefaultAndCorruptSettingsDisableSending() throws {
        try isolated { defaults, store in
            XCTAssertEqual(store.load(), DecisionsSettings())
            XCTAssertEqual(store.load().threshold, 0.5)
            defaults.set(Data("bad".utf8), forKey: "decisionsSettings")
            XCTAssertFalse(store.load().enabled)
            XCTAssertFalse(store.load().consent)
            XCTAssertEqual(store.load().threshold, 0.5)
            var bad = DecisionsSettings()
            bad.enabled = true
            bad.threshold = 2
            defaults.set(try JSONEncoder().encode(bad), forKey: "decisionsSettings")
            XCTAssertEqual(store.load(), DecisionsSettings())
        }
    }

    func testSettingsRoundTripIsSeparateFromManualConversionPreferences() throws {
        try isolated { defaults, store in
            defaults.set("unchanged", forKey: "aiDataSharingConsentEndpoint")
            var settings = DecisionsSettings()
            settings.enabled = true
            settings.consent = true
            // Changing defaults must not raise an existing user's saved ceiling.
            settings.maximumCalls = 1_000
            settings.threshold = 0.6 // A saved choice must survive a default change.
            try store.save(settings)
            XCTAssertEqual(store.load(), settings)
            XCTAssertEqual(DecisionsSettingsStore(defaults: defaults).load().maximumCalls, 1_000)
            XCTAssertEqual(defaults.string(forKey: "aiDataSharingConsentEndpoint"), "unchanged")
            settings.threshold = -1
            XCTAssertThrowsError(try store.save(settings))
            XCTAssertEqual(store.load().threshold, 0.6)
        }
    }

    func testCallCeilingPersistsAcrossNewStoreAndOnlyExplicitResetClearsIt() throws {
        try isolated { defaults, store in
            XCTAssertEqual(store.calls, 0)
            XCTAssertTrue(store.reserve(limit: 2))
            XCTAssertTrue(DecisionsSettingsStore(defaults: defaults).reserve(limit: 2))
            XCTAssertFalse(DecisionsSettingsStore(defaults: defaults).reserve(limit: 2))
            XCTAssertEqual(store.calls, 2)
            try store.save(DecisionsSettings())
            XCTAssertEqual(store.calls, 2)
            store.resetCalls()
            XCTAssertEqual(store.calls, 0)
            XCTAssertTrue(store.reserve(limit: 2))
        }
    }

    func testLegacyMigrationCopiesOnlyNumericPreferencesAndLeavesOldDataUntouched() throws {
        try isolated { defaults, store in
            let legacy = try JSONSerialization.data(withJSONObject: ["enabled": true, "consent": true,
                "model": "jev-latest", "threshold": 0.6, "maximumCalls": 20_000])
            defaults.set(legacy, forKey: "jevSettings")
            defaults.set(974, forKey: "jevCallCount")
            let fresh = store.load()
            XCTAssertEqual(fresh.threshold, 0.6); XCTAssertEqual(fresh.maximumCalls, 20_000)
            XCTAssertEqual(fresh.model, "gpt-6-luna"); XCTAssertEqual(fresh.batchWindowMilliseconds, 200)
            XCTAssertFalse(fresh.enabled); XCTAssertFalse(fresh.consent); XCTAssertEqual(store.calls, 0)
            XCTAssertEqual(defaults.data(forKey: "jevSettings"), legacy)
            XCTAssertEqual(defaults.integer(forKey: "jevCallCount"), 974)
            var saved = fresh; saved.threshold = 0.95; try store.save(saved)
            XCTAssertEqual(store.load().threshold, 0.95)
            XCTAssertTrue(store.reserve(limit: 2)); store.resetCalls()
            XCTAssertEqual(defaults.integer(forKey: "jevCallCount"), 974)
        }
    }
}
