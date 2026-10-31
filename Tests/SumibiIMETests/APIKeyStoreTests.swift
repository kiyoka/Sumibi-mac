import XCTest
import Security
@testable import SumibiIME

final class APIKeyStoreTests: XCTestCase {
    func testLoadUsesStableServiceAndLocalOnlyQuery() throws {
        let fake = RecordingKeychain()
        fake.loadResult = (errSecSuccess, Data("fake-test-key".utf8) as CFData)
        XCTAssertEqual(try APIKeyStore(keychain: fake).load(), "fake-test-key")
        let query = try XCTUnwrap(fake.queries.first)
        assertBaseQuery(query)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    func testMissingKeyReturnsNilAndAccessFailureIsNotHidden() throws {
        let fake = RecordingKeychain()
        XCTAssertNil(try APIKeyStore(keychain: fake).load())
        fake.loadResult = (errSecInteractionNotAllowed, nil)
        XCTAssertThrowsError(try APIKeyStore(keychain: fake).load()) {
            XCTAssertEqual($0 as? APIKeyStoreError, .keychain(errSecInteractionNotAllowed))
        }
    }

    func testUnexpectedTypeOrInvalidUTF8IsRejected() {
        let fake = RecordingKeychain()
        for value: CFTypeRef in ["not-data" as CFString, Data([0xff]) as CFData] {
            fake.loadResult = (errSecSuccess, value)
            XCTAssertThrowsError(try APIKeyStore(keychain: fake).load()) {
                XCTAssertEqual($0 as? APIKeyStoreError, .unexpectedData)
            }
        }
    }

    func testSaveUpdatesExistingKeyWithoutAddingAnother() throws {
        let fake = RecordingKeychain()
        fake.updateStatus = errSecSuccess
        try APIKeyStore(keychain: fake).save("fake-key")
        XCTAssertEqual(fake.calls, ["update"])
        assertBaseQuery(try XCTUnwrap(fake.queries.first))
        let attributes = try XCTUnwrap(fake.attributes.first)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("fake-key".utf8))
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testSaveAddsOnlyWhenUpdateReportsNotFound() throws {
        let fake = RecordingKeychain()
        try APIKeyStore(keychain: fake).save("fake-key")
        XCTAssertEqual(fake.calls, ["update", "add"])
        let item = try XCTUnwrap(fake.items.first)
        assertBaseQuery(item)
        XCTAssertEqual(item[kSecValueData as String] as? Data, Data("fake-key".utf8))
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testUpdateFailureDoesNotFallBackToAdd() {
        let fake = RecordingKeychain()
        fake.updateStatus = errSecAuthFailed
        XCTAssertThrowsError(try APIKeyStore(keychain: fake).save("fake-key")) {
            XCTAssertEqual($0 as? APIKeyStoreError, .keychain(errSecAuthFailed))
        }
        XCTAssertEqual(fake.calls, ["update"])
    }

    func testAddFailureIsReported() {
        let fake = RecordingKeychain()
        fake.addStatus = errSecDuplicateItem
        XCTAssertThrowsError(try APIKeyStore(keychain: fake).save("fake-key")) {
            XCTAssertEqual($0 as? APIKeyStoreError, .keychain(errSecDuplicateItem))
        }
    }

    func testDeleteIsScopedAndIdempotentButReportsFailure() throws {
        let fake = RecordingKeychain()
        let store = APIKeyStore(keychain: fake)
        for status in [errSecSuccess, errSecItemNotFound] {
            fake.deleteStatus = status
            try store.delete()
        }
        assertBaseQuery(try XCTUnwrap(fake.queries.last))
        fake.deleteStatus = errSecAuthFailed
        XCTAssertThrowsError(try store.delete()) {
            XCTAssertEqual($0 as? APIKeyStoreError, .keychain(errSecAuthFailed))
        }
    }

    func testEndpointScopedAccountsIsolateKeysPerDestination() throws {
        let fake = RecordingKeychain(storage: [:])
        let store = APIKeyStore(keychain: fake)
        let openAIEndpoint = "https://api.openai.com"
        let googleEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai"
        let customOne = "https://one.example.com/v1"
        let customTwo = "https://two.example.com/v1"

        try store.save("sk-openai-key", for: openAIEndpoint)
        try store.save("AIza-google-key", for: googleEndpoint)
        try store.save("custom-key-1", for: customOne)

        XCTAssertEqual(try store.load(for: openAIEndpoint), "sk-openai-key")
        XCTAssertEqual(try store.load(for: googleEndpoint), "AIza-google-key")
        XCTAssertEqual(try store.load(for: customOne), "custom-key-1")
        XCTAssertNil(try store.load(for: customTwo))

        XCTAssertNotNil(fake.storage?["endpoint:https://api.openai.com"])
        XCTAssertNotNil(fake.storage?["endpoint:https://generativelanguage.googleapis.com/v1beta/openai"])
        XCTAssertNotNil(fake.storage?["endpoint:https://one.example.com/v1"])

        try store.delete(for: openAIEndpoint)
        XCTAssertNil(try store.load(for: openAIEndpoint))
        XCTAssertEqual(try store.load(for: googleEndpoint), "AIza-google-key")
        XCTAssertEqual(try store.load(for: customOne), "custom-key-1")
    }

    func testLegacyDefaultKeyMigratesOnlyToItsOriginalOwnerEndpoint() throws {
        let fake = RecordingKeychain(storage: ["default": Data("legacy-custom-key".utf8)])
        let store = APIKeyStore(keychain: fake)
        let ownerEndpoint = "https://legacy.example.com/v1"
        let googleEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai"

        // Loading for Google must NOT claim or migrate the legacy key owned by legacy.example.com.
        XCTAssertNil(try store.load(for: googleEndpoint, legacyOwnerEndpoint: ownerEndpoint))
        XCTAssertNotNil(fake.storage?["default"])
        XCTAssertNil(fake.storage?["endpoint:\(googleEndpoint)"])

        // Loading for the original owner endpoint migrates the key and deletes "default".
        var checked = false
        XCTAssertEqual(
            try store.load(for: ownerEndpoint, legacyOwnerEndpoint: ownerEndpoint, onLegacyChecked: { checked = true }),
            "legacy-custom-key"
        )
        XCTAssertTrue(checked)
        XCTAssertNil(fake.storage?["default"])
        XCTAssertEqual(
            fake.storage?["endpoint:\(ownerEndpoint)"],
            Data("legacy-custom-key".utf8)
        )
    }

    private func assertBaseQuery(_ query: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "org.sumibi.Sumibi-mac.api-key", file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "default", file: file, line: line)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, file: file, line: line)
    }
}

final class RecordingKeychain: KeychainAccess {
    var storage: [String: Data]?
    var loadResult: (OSStatus, CFTypeRef?) = (errSecItemNotFound, nil)
    var updateStatus = errSecItemNotFound
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    var calls: [String] = []
    var queries: [[String: Any]] = []
    var attributes: [[String: Any]] = []
    var items: [[String: Any]] = []

    init(storage: [String: Data]? = nil) {
        self.storage = storage
    }

    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        let dict = query as! [String: Any]
        calls.append("load"); queries.append(dict)
        if let storage {
            guard let account = dict[kSecAttrAccount as String] as? String,
                  let data = storage[account] else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, data as CFData)
        }
        return loadResult
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        let dict = query as! [String: Any]
        let attrs = attributes as! [String: Any]
        calls.append("update"); queries.append(dict); self.attributes.append(attrs)
        if var storage {
            guard let account = dict[kSecAttrAccount as String] as? String,
                  storage[account] != nil,
                  let data = attrs[kSecValueData as String] as? Data else {
                return errSecItemNotFound
            }
            storage[account] = data
            self.storage = storage
            return errSecSuccess
        }
        return updateStatus
    }
    func add(_ item: CFDictionary) -> OSStatus {
        let dict = item as! [String: Any]
        calls.append("add"); items.append(dict)
        if var storage {
            if let account = dict[kSecAttrAccount as String] as? String,
               let data = dict[kSecValueData as String] as? Data {
                storage[account] = data
                self.storage = storage
            }
        }
        return addStatus
    }
    func delete(_ query: CFDictionary) -> OSStatus {
        let dict = query as! [String: Any]
        calls.append("delete"); queries.append(dict)
        if var storage, let account = dict[kSecAttrAccount as String] as? String {
            storage.removeValue(forKey: account)
            self.storage = storage
        }
        return deleteStatus
    }
}
