import XCTest
import Security
import SumibiPrototypeCore
@testable import SumibiPrototypeIME

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

    private var longFakeKey: String { "sk-" + String(repeating: "x", count: 200) + "AB12" }
    private func model(_ keys: RecordingKeychain) -> APISettingsModel {
        let domain = "org.sumibi.tests.settings-model.\(UUID().uuidString)"
        domains.append(domain)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: domain)!, prototypeDefaults: { nil })
        return APISettingsModel(settings: settings, keys: APIKeyStore(keychain: keys))
    }
}
