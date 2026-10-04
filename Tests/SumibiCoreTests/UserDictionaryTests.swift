import XCTest
@testable import SumibiCore

final class UserDictionaryTests: XCTestCase {
    func testValidEntriesAllowPreservingReplacementCaseAndEquals() {
        let result = UserDictionary.validate("sumibi = Sumibi\nkey = A=B\n")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.entries, [
            .init(reading: "sumibi", replacement: "Sumibi"),
            .init(reading: "key", replacement: "A=B")
        ])
    }

    func testInvalidReadingAndDuplicateShowLineNumbers() {
        let result = UserDictionary.validate("ABC = 大文字\nsumibi = 炭火\nsumibi = Sumibi\nかな = 仮名\nno separator")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.map(\.lineNumber), [1, 3, 4, 5])
        XCTAssertEqual(result.entries, [.init(reading: "sumibi", replacement: "炭火")])
    }

    func testEntryAndCharacterLimits() {
        let entries = (1 ... 101).map { "entry\($0) = 候補" }.joined(separator: "\n")
        XCTAssertTrue(UserDictionary.validate(entries).errors.contains { $0.reason.contains("100件") })
        XCTAssertTrue(UserDictionary.validate(String(repeating: "a", count: 2_001))
            .errors.contains { $0.reason.contains("2,000文字") })
    }
}
