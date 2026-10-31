import XCTest
import Security
import SumibiCore
@testable import SumibiIME

final class DecisionsSettingsModelTests: XCTestCase {
    private func isolated(_ body: (DecisionsSettingsModel, DecisionsSettingsStore, RecordingKeychain, SettingsStore) throws -> Void) throws {
        let name = "org.sumibi.tests.decisions-ui.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DecisionsSettingsStore(defaults: defaults)
        let manual = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        manual.saveConsent(for: ProviderConfiguration.defaultEndpoint)
        let fake = RecordingKeychain()
        fake.loadResult = (errSecSuccess, Data("fake-openai-key-abcd".utf8) as CFData)
        let model = DecisionsSettingsModel(store: store, keys: APIKeyStore(keychain: fake), manualSettings: manual)
        try body(model, store, fake, manual)
    }

    func testExistingOpenAIKeyIsMaskedAndNeverWrittenByThisScreen() throws {
        try isolated { model, _, fake, _ in
            model.reload()
            XCTAssertEqual(model.storedKeyDisplay, "****abcd")
            XCTAssertTrue(model.hasStoredKey)
            XCTAssertEqual(fake.calls, ["load"])
            XCTAssertEqual(fake.queries.first?[kSecAttrService as String] as? String, "org.sumibi.Sumibi-mac.api-key")
        }
    }

    func testGlobalEnableRequiresIndependentConsentManualConsentAndKey() throws {
        try isolated { model, store, fake, manual in
            model.reload(); model.setEnabled(true)
            XCTAssertFalse(store.load().enabled)
            model.setConsent(true)
            manual.revokeConsent(); model.setEnabled(true)
            XCTAssertFalse(store.load().enabled)
            manual.saveConsent(for: ProviderConfiguration.defaultEndpoint)
            fake.loadResult = (errSecItemNotFound, nil); model.setEnabled(true)
            XCTAssertFalse(store.load().enabled)
            fake.loadResult = (errSecSuccess, Data("fake-key".utf8) as CFData); model.setEnabled(true)
            XCTAssertTrue(store.load().permitsSending)
            XCTAssertTrue(fake.calls.allSatisfy { $0 == "load" })
        }
    }

    func testForeignProviderFailsBeforeReadingKey() throws {
        try isolated { model, store, fake, manual in
            try manual.saveProviderConfiguration(.init(endpoint: "https://other.invalid", model: "other"))
            model.reload(); model.setConsent(true); model.setEnabled(true)
            XCTAssertTrue(fake.calls.isEmpty)
            XCTAssertFalse(store.load().enabled)
            XCTAssertTrue(model.statusMessage.contains("公式OpenAI"))
        }
    }

    func testGoogleProviderAllowsSavingAndUpdatingOpenAIKeyAndEnablingDecisions() throws {
        let name = "org.sumibi.tests.decisions-ui-google.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DecisionsSettingsStore(defaults: defaults)
        let manual = SettingsStore(defaults: defaults, prototypeDefaults: { nil })
        let google = ProviderConfiguration(
            provider: .google,
            endpoint: AIProvider.google.defaultEndpoint,
            model: GeminiModelOption.quality.rawValue
        )
        try manual.saveProviderConfiguration(google)
        manual.saveConsent(for: google.endpoint)

        let keychain = RecordingKeychain(storage: [
            "endpoint:https://generativelanguage.googleapis.com/v1beta/openai": Data("AIzaSy-google-key-9999".utf8)
        ])
        let model = DecisionsSettingsModel(store: store, keys: APIKeyStore(keychain: keychain), manualSettings: manual)

        model.reload()
        XCTAssertTrue(model.isSupportedProvider)
        XCTAssertEqual(model.conversionProvider, .google)
        XCTAssertEqual(model.conversionProviderName, "Google")
        XCTAssertEqual(model.conversionModelDisplay, "gemini-3.6-flash")
        XCTAssertEqual(model.conversionKeyDisplay, "****9999")
        XCTAssertTrue(model.hasConversionConsent)
        XCTAssertNil(model.storedKeyDisplay)
        XCTAssertFalse(model.hasStoredKey)
        XCTAssertTrue(model.showsOpenAIKeyEditor)

        // Cannot enable without OpenAI key even if consent is turned on.
        model.setConsent(true)
        XCTAssertTrue(store.load().consent)
        XCTAssertTrue(store.hasConsent(forConversionEndpoint: google.endpoint))
        model.setEnabled(true)
        XCTAssertFalse(store.load().enabled)
        XCTAssertTrue(model.statusIsError)

        // Save OpenAI key from DecisionsSettingsModel.
        model.openAIKeyInput = "sk-openai-key-1234"
        model.saveOpenAIKey()
        XCTAssertFalse(model.statusIsError)
        XCTAssertEqual(model.storedKeyDisplay, "****1234")
        XCTAssertTrue(model.hasStoredKey)
        XCTAssertFalse(model.showsOpenAIKeyEditor)
        XCTAssertTrue(model.openAIKeyInput.isEmpty)
        XCTAssertEqual(keychain.storage?["endpoint:https://api.openai.com"], Data("sk-openai-key-1234".utf8))
        XCTAssertEqual(
            keychain.storage?["endpoint:https://generativelanguage.googleapis.com/v1beta/openai"],
            Data("AIzaSy-google-key-9999".utf8)
        )

        // Begin and cancel editing OpenAI key.
        model.beginOpenAIKeyEditing()
        XCTAssertTrue(model.showsOpenAIKeyEditor)
        model.openAIKeyInput = "sk-unsaved"
        model.cancelOpenAIKeyEditing()
        XCTAssertFalse(model.showsOpenAIKeyEditor)
        XCTAssertEqual(model.storedKeyDisplay, "****1234")

        // Update OpenAI key to a new value.
        model.beginOpenAIKeyEditing()
        model.openAIKeyInput = "sk-openai-key-5678"
        model.saveOpenAIKey()
        XCTAssertEqual(model.storedKeyDisplay, "****5678")
        XCTAssertEqual(keychain.storage?["endpoint:https://api.openai.com"], Data("sk-openai-key-5678".utf8))

        // Now enabling Decisions succeeds.
        model.setEnabled(true)
        XCTAssertFalse(model.statusIsError)
        XCTAssertTrue(store.load().permitsSending)
    }

    func testProviderChangeResetsDecisionsEnabledAndRequiresReconsentOnReload() throws {
        try isolated { model, store, _, manual in
            model.reload()
            model.setConsent(true)
            model.setEnabled(true)
            XCTAssertTrue(store.load().enabled)
            XCTAssertTrue(store.load().consent)
            XCTAssertTrue(store.hasConsent(forConversionEndpoint: ProviderConfiguration.defaultEndpoint))

            // Switch conversion provider to Google externally and reload DecisionsSettingsModel.
            let google = ProviderConfiguration(
                provider: .google,
                endpoint: AIProvider.google.defaultEndpoint,
                model: GeminiModelOption.quality.rawValue
            )
            try manual.saveProviderConfiguration(google)
            manual.saveConsent(for: google.endpoint)

            model.reload()
            XCTAssertFalse(model.settings.enabled)
            XCTAssertFalse(model.settings.consent)
            XCTAssertFalse(store.load().enabled)
            XCTAssertFalse(store.load().consent)
            XCTAssertFalse(store.hasConsent(forConversionEndpoint: google.endpoint))
            XCTAssertTrue(model.statusMessage.contains("再度同意"))
        }
    }

    func testRevokingConsentDisablesAndPreservesKeyCallsAndManualConsent() throws {
        try isolated { model, store, fake, manual in
            model.reload(); model.setConsent(true); model.setEnabled(true)
            XCTAssertTrue(store.reserve(limit: 10))
            model.setConsent(false)
            XCTAssertFalse(store.load().enabled); XCTAssertFalse(store.load().consent)
            XCTAssertEqual(store.calls, 1)
            XCTAssertTrue(manual.hasConsent(for: ProviderConfiguration.defaultEndpoint))
            XCTAssertTrue(fake.calls.allSatisfy { $0 == "load" })
        }
    }

    func testLimitArrowsAutosaveSnapAndPersistAcrossReload() throws {
        for (initial, up, down) in [(1, 1_000, 1_000), (1_001, 2_000, 1_000), (10_000, 11_000, 9_000), (1_000_000, 1_000_000, 999_000)] {
            for increasing in [false, true] {
                try isolated { model, store, _, _ in
                    var settings = DecisionsSettings(); settings.maximumCalls = initial
                    try store.save(settings); model.reload()
                    model.adjustMaximumCalls(increasing: increasing)
                    model.reload()
                    XCTAssertEqual(model.settings.maximumCalls, increasing ? up : down)
                    XCTAssertEqual(store.load().maximumCalls, increasing ? up : down)
                }
            }
        }
    }

    func testThresholdAutosavesRejectsInvalidAndDoesNotResetCount() throws {
        try isolated { model, store, _, _ in
            model.reload(); XCTAssertTrue(store.reserve(limit: 10))
            model.setThreshold(0.95)
            for value in [-0.1, 1.1, Double.nan, .infinity] { model.setThreshold(value) }
            model.reload()
            XCTAssertEqual(store.load().threshold, 0.95); XCTAssertEqual(model.settings.threshold, 0.95)
            XCTAssertEqual(store.calls, 1)
        }
    }

    func testExplicitCounterResetChangesRevisionWithoutChangingPreferences() throws {
        try isolated { model, store, fake, _ in
            model.reload(); model.setConsent(true); XCTAssertTrue(store.reserve(limit: 2))
            let settings = store.load(); let revision = store.revision
            model.resetCalls()
            XCTAssertEqual(store.calls, 0); XCTAssertEqual(store.load(), settings)
            XCTAssertNotEqual(store.revision, revision); XCTAssertEqual(fake.calls, ["load"])
        }
    }

    func testKeyLoadFailureShowsSafeMessageWithoutMutation() throws {
        try isolated { model, _, fake, _ in
            fake.loadResult = (errSecInteractionNotAllowed, nil); model.reload()
            XCTAssertFalse(model.hasStoredKey); XCTAssertTrue(model.statusIsError)
            XCTAssertEqual(fake.calls, ["load"])
        }
    }
}
