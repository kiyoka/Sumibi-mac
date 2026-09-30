import XCTest
@testable import SumibiPrototypeCore

final class HomophoneDictionaryTests: XCTestCase {
    private let dictionary = HomophoneDictionary(tsv: """
        # SudachiDict Core
        はし\t橋\t端\t箸\t椅
        かみ\t紙\t神\t髪
        """)

    func testAppendsDictionaryCandidatesAfterLLMWithoutDuplicates() {
        XCTAssertEqual(
            dictionary.supplement(["橋", "はし", "端", "英語の橋"]),
            ["橋", "はし", "端", "英語の橋", "箸", "椅"]
        )
    }

    func testLimitsOnlyAdditionalCandidates() {
        XCTAssertEqual(dictionary.supplement(["はし"], maximumAdded: 2), ["はし", "橋", "端"])
    }

    func testDoesNotSupplementWithoutWholeHiraganaWord() {
        XCTAssertEqual(dictionary.supplement(["橋", "このはしを渡る"]), ["橋", "このはしを渡る"])
    }

    func testDoesNotSupplementUnknownReading() {
        XCTAssertEqual(dictionary.supplement(["きょう"]), ["きょう"])
    }

    func testBundledIndexContainsRepresentativeHomophones() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let index = repository.appendingPathComponent("Prototype/Resources/SudachiCandidates.tsv")
        let bundled = try HomophoneDictionary(contentsOf: index)
        let candidates = bundled.supplement(["橋", "はし"])
        XCTAssertTrue(candidates.contains("箸"))
        XCTAssertTrue(candidates.contains("端"))
    }
}
