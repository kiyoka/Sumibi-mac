import XCTest
import Security
import SumibiCore
@testable import SumibiIME

final class APISettingsModelTests: XCTestCase {
    private var domains: [String] = []
    override func tearDown() {
        for domain in domains { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        domains = []
        super.tearDown()
    }

    func testReloadShowsCompactSavedKeyWithoutPuttingItInEditableField() {
        let keys = RecordingKeychain()
        keys.loadResult = (errSecSuccess, Data(longFakeKey.utf8) as CFData)
        let model = model(keys)
        model.reload()
        XCTAssertEqual(model.storedAPIKeyDisplay, "****AB12")
        XCTAssertFalse(model.showsAPIKeyEditor)
        XCTAssertTrue(model.hasStoredAPIKey)
        XCTAssertTrue(model.apiKey.isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSavingConfigurationDoesNotSaveThePlaceholderAsAKey() {
        let keys = RecordingKeychain()
        keys.loadResult = (errSecSuccess, Data(longFakeKey.utf8) as CFData)
        let model = model(keys)
        model.reload()
        model.modelChoice = .custom
        model.customModelName = "custom-model"
        model.save()
        XCTAssertEqual(keys.calls, ["load"])
        XCTAssertEqual(model.storedAPIKeyDisplay, "****AB12")
        XCTAssertTrue(model.apiKey.isEmpty)
    }

    func testSavingANewKeyClearsEditableFieldAndUpdatesCompactMask() {
        let keys = RecordingKeychain()
        keys.updateStatus = errSecSuccess
        let model = model(keys)
        model.reload()
        model.apiKey = longFakeKey
        model.save()
        XCTAssertEqual(keys.calls, ["load", "update"])
        XCTAssertEqual(keys.attributes.first?[kSecValueData as String] as? Data, Data(longFakeKey.utf8))
        XCTAssertEqual(model.storedAPIKeyDisplay, "****AB12")
        XCTAssertFalse(model.isEditingAPIKey)
        XCTAssertTrue(model.apiKey.isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testNoKeyShowsEntryPromptAndReadFailureDoesNotExposePreviousValue() {
        let keys = RecordingKeychain()
        let model = model(keys)
        model.reload()
        XCTAssertTrue(model.showsAPIKeyEditor)
        XCTAssertFalse(model.hasStoredAPIKey)
        keys.loadResult = (errSecSuccess, Data(longFakeKey.utf8) as CFData)
        model.reload()
        keys.loadResult = (errSecInteractionNotAllowed, nil)
        model.reload()
        XCTAssertNil(model.storedAPIKeyDisplay)
        XCTAssertTrue(model.showsAPIKeyEditor)
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.apiKey.isEmpty)
    }

    func testBeginAndCancelEditingDoNotTouchSavedKey() {
        let keys = RecordingKeychain()
        keys.loadResult = (errSecSuccess, Data(longFakeKey.utf8) as CFData)
        let model = model(keys)
        model.reload()
        model.beginAPIKeyEditing()
        XCTAssertTrue(model.showsAPIKeyEditor)
        XCTAssertTrue(model.apiKey.isEmpty)
        model.apiKey = "new-fake-key"
        XCTAssertTrue(model.hasUnsavedChanges)
        model.cancelAPIKeyEditing()
        XCTAssertFalse(model.showsAPIKeyEditor)
        XCTAssertTrue(model.apiKey.isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.storedAPIKeyDisplay, "****AB12")
        XCTAssertEqual(keys.calls, ["load"])
    }

    func testFailedKeySaveKeepsEditorAndPreviousSavedDisplay() {
        let keys = RecordingKeychain()
        keys.loadResult = (errSecSuccess, Data(longFakeKey.utf8) as CFData)
        keys.updateStatus = errSecAuthFailed
        let model = model(keys)
        model.reload()
        model.beginAPIKeyEditing()
        model.apiKey = "new-fake-key"
        model.save()
        XCTAssertTrue(model.showsAPIKeyEditor)
        XCTAssertEqual(model.apiKey, "new-fake-key")
        XCTAssertEqual(model.storedAPIKeyDisplay, "****AB12")
        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(keys.calls, ["load", "update"])
    }

    func testSwitchingBetweenOpenAIAndGooglePreservesEachProviderModelAndKey() {
        let keys = RecordingKeychain(storage: [:])
        let domain = "org.sumibi.tests.settings-model.\(UUID().uuidString)"
        domains.append(domain)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: domain)!, prototypeDefaults: { nil })
        let model = APISettingsModel(settings: settings, keys: APIKeyStore(keychain: keys))

        model.reload()
        XCTAssertEqual(model.provider, .openAI)
        XCTAssertEqual(model.endpoint, "https://api.openai.com")
        XCTAssertEqual(model.modelName, "gpt-6-sol")

        model.modelChoice = .preset(.gpt6Luna)
        model.apiKey = "sk-openai-key-1111"
        model.save()
        model.setConsent(true)
        XCTAssertTrue(model.hasConsent)
        XCTAssertEqual(model.storedAPIKeyDisplay, "****1111")
        XCTAssertTrue(model.isDecisionsSupported)

        // Switch to Google
        model.selectProvider(.google)
        XCTAssertEqual(model.provider, .google)
        XCTAssertEqual(model.endpoint, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(model.geminiModel, .quality)
        XCTAssertEqual(model.modelName, "gemini-3.6-flash")
        XCTAssertNil(model.storedAPIKeyDisplay)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.hasConsent)

        // Consent cannot be turned on before saving the changed provider/endpoint.
        model.setConsent(true)
        XCTAssertFalse(model.hasConsent)
        XCTAssertTrue(model.statusIsError)

        model.geminiModel = .economy
        model.apiKey = "AIzaSyDummyGoogleKey2222"
        model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.hasConsent)
        XCTAssertFalse(model.isDecisionsSupported)
        XCTAssertEqual(model.storedAPIKeyDisplay, "****2222")

        model.setConsent(true)
        XCTAssertTrue(model.hasConsent)

        // Switch back to OpenAI and verify OpenAI's model and key are still intact.
        model.selectProvider(.openAI)
        XCTAssertEqual(model.endpoint, "https://api.openai.com")
        XCTAssertEqual(model.modelChoice, .preset(.gpt6Luna))
        XCTAssertEqual(model.storedAPIKeyDisplay, "****1111")

        // Switch back to Google and verify Google's model and key are still intact.
        model.selectProvider(.google)
        XCTAssertEqual(model.endpoint, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(model.geminiModel, .economy)
        XCTAssertEqual(model.storedAPIKeyDisplay, "****2222")

        // Deleting Google's key does not delete OpenAI's key.
        model.deleteAPIKey()
        XCTAssertNil(model.storedAPIKeyDisplay)
        model.selectProvider(.openAI)
        XCTAssertEqual(model.storedAPIKeyDisplay, "****1111")
    }

    func testChangingCustomEndpointInOtherProviderDoesNotCarryOverPreviousEndpointKey() {
        let keys = RecordingKeychain(storage: [:])
        let domain = "org.sumibi.tests.settings-model.\(UUID().uuidString)"
        domains.append(domain)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: domain)!, prototypeDefaults: { nil })
        let model = APISettingsModel(settings: settings, keys: APIKeyStore(keychain: keys))

        model.reload()
        model.selectProvider(.other)
        model.endpoint = "https://one.example.com/v1"
        model.customModelName = "model-one"
        model.apiKey = "sk-custom-one-3333"
        model.save()
        XCTAssertEqual(model.storedAPIKeyDisplay, "****3333")

        // Changing the custom URL must immediately clear the displayed key for the new URL
        // and must not copy one.example.com's key to two.example.com.
        model.endpoint = "https://two.example.com/v1"
        XCTAssertNil(model.storedAPIKeyDisplay)
        XCTAssertTrue(model.showsAPIKeyEditor)
        model.save()
        XCTAssertNil(model.storedAPIKeyDisplay)
        XCTAssertNil(keys.storage?["endpoint:https://two.example.com/v1"])
        XCTAssertEqual(keys.storage?["endpoint:https://one.example.com/v1"], Data("sk-custom-one-3333".utf8))
    }

    private var longFakeKey: String { "sk-" + String(repeating: "x", count: 200) + "AB12" }
    private func model(_ keys: RecordingKeychain) -> APISettingsModel {
        let domain = "org.sumibi.tests.settings-model.\(UUID().uuidString)"
        domains.append(domain)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: domain)!, prototypeDefaults: { nil })
        return APISettingsModel(settings: settings, keys: APIKeyStore(keychain: keys))
    }
}
