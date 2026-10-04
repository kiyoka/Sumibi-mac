import XCTest
import Security
@testable import SumibiPrototypeIME

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

    private func assertBaseQuery(_ query: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "org.sumibi.Sumibi-mac.api-key", file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "default", file: file, line: line)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, file: file, line: line)
    }
}

final class RecordingKeychain: KeychainAccess {
    var loadResult: (OSStatus, CFTypeRef?) = (errSecItemNotFound, nil)
    var updateStatus = errSecItemNotFound
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    var calls: [String] = []
    var queries: [[String: Any]] = []
    var attributes: [[String: Any]] = []
    var items: [[String: Any]] = []
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        calls.append("load"); queries.append(query as! [String: Any]); return loadResult
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        calls.append("update"); queries.append(query as! [String: Any]); self.attributes.append(attributes as! [String: Any]); return updateStatus
    }
    func add(_ item: CFDictionary) -> OSStatus {
        calls.append("add"); items.append(item as! [String: Any]); return addStatus
    }
    func delete(_ query: CFDictionary) -> OSStatus {
        calls.append("delete"); queries.append(query as! [String: Any]); return deleteStatus
    }
}
