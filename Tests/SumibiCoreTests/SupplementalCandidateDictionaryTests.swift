import XCTest
@testable import SumibiCore

final class SupplementalCandidateDictionaryTests: XCTestCase {
    private let fixture = SupplementalCandidateDictionary(symbolTSV: """
        # fixture
        hoshi\t☆\t★\t☆
        ten\t点\t・
        はし\t→
        """, homophones: HomophoneDictionary(tsv: "はし\t橋\t端\t箸"))

    func testSymbolsDoNotRequireHiraganaLLMCandidateAndPreserveOrderAndModel() {
        let result = fixture.supplement(.init(candidates: ["星", "star"], model: "model"), source: "HOSHI")
        XCTAssertEqual(result.candidates, ["星", "star", "☆", "★"])
        XCTAssertEqual(result.dictionaryCandidates, ["☆", "★"])
        XCTAssertEqual(result.model, "model")
    }

    func testWholeSourceOnlyAndNoCompatibilityNormalization() {
        for source in ["my hoshi", "hoshi.", " hoshi", "hoshi ", "①", "unknown", "ＴＥＮ"] {
            XCTAssertEqual(fixture.supplement(.init(candidates: ["元"]), source: source).candidates, ["元"])
        }
    }

    func testMiddleDotHasPriorityAndWholeInputAliases() {
        for source in ["ten", "TEN", "nakaguro", "."] {
            let result = fixture.supplement(.init(candidates: ["元"]), source: source, maximumAdded: 1)
            XCTAssertEqual(result.candidates, ["元", "・"])
        }
        for source in ["sentence.", "ten ten", "ten\n"] {
            XCTAssertEqual(fixture.supplement(.init(candidates: ["元"]), source: source).candidates, ["元"])
        }
    }

    func testLLMProvenanceIsNotReassignedAndDuplicateSymbolsAreRemoved() {
        let result = fixture.supplement(.init(candidates: ["☆", "星"]), source: "hoshi")
        XCTAssertEqual(result.candidates, ["☆", "星", "★"])
        XCTAssertEqual(result.dictionaryCandidates, ["★"])
        let retained = fixture.supplement(.init(candidates: ["☆"], dictionaryCandidates: ["☆"]), source: "hoshi")
        XCTAssertEqual(retained.dictionaryCandidates, ["☆", "★"])
    }

    func testOneBudgetAcrossSymbolsAndExistingHomophones() {
        let result = fixture.supplement(.init(candidates: ["はし", "橋"]), source: "はし", maximumAdded: 2)
        XCTAssertEqual(result.candidates, ["はし", "橋", "→", "端"])
        XCTAssertEqual(result.dictionaryCandidates, ["→", "端"])
        XCTAssertEqual(fixture.supplement(.init(candidates: ["元"]), source: "hoshi", maximumAdded: 0).candidates, ["元"])
    }

    func testMissingSymbolIndexKeepsMiddleDotAndHomophones() {
        let dictionary = SupplementalCandidateDictionary(homophones: HomophoneDictionary(tsv: "はし\t橋\t箸"))
        XCTAssertEqual(dictionary.supplement(.init(candidates: ["はし"]), source: "hashi").candidates, ["はし", "橋", "箸"])
        XCTAssertEqual(dictionary.supplement(.init(candidates: ["点"]), source: "ten").candidates, ["点", "・"])
        XCTAssertEqual(SupplementalCandidateDictionary().supplement(.init(candidates: ["星"]), source: "hoshi").candidates, ["星"])
    }

    func testDefaultBudgetAddsAtMostTenAcrossBothDictionaries() {
        let symbols = (0..<20).map { "記号\($0)" }
        let dictionary = SupplementalCandidateDictionary(symbolTSV: "ten\t" + symbols.joined(separator: "\t"),
            homophones: HomophoneDictionary(tsv: "てん\t点\t天"))
        let result = dictionary.supplement(.init(candidates: ["てん"]), source: "ten")
        XCTAssertEqual(result.candidates, ["てん", "・"] + symbols.prefix(9))
        XCTAssertEqual(result.dictionaryCandidates.count, 10)
    }

    func testSessionKeepsCurrentCandidateAndOriginalWhenSymbolsArrive() {
        let session = InputSession()
        _ = session.receive(.text("hoshi"))
        _ = session.receive(.convert)
        _ = session.completeFirst(id: session.pending!.id, result: "星")
        _ = session.receive(.convert, canReplacePrevious: true)
        let supplemented = fixture.supplement(.init(candidates: ["ほし", "☆"]), source: "hoshi")
        _ = session.completeAlternatives(id: session.pending!.id, alternatives: supplemented.candidates)
        XCTAssertEqual(session.candidateStrings.first, "星")
        XCTAssertTrue(session.candidateStrings.contains("★"))
        XCTAssertEqual(session.previous?.source, "hoshi")
        XCTAssertEqual(session.previous?.result, "星")
        XCTAssertFalse(supplemented.dictionaryCandidates.contains("☆"))
    }

    func testBundledRepresentativesAndTenCandidateLimit() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tsv = try String(contentsOf: repository.appendingPathComponent("App/Resources/MozcSymbols.tsv"), encoding: .utf8)
        let dictionary = SupplementalCandidateDictionary(symbolTSV: tsv)
        for (reading, symbols) in [("hoshi", ["☆", "★"]), ("hosi", ["☆", "★"]), ("ほし", ["☆", "★"]),
                                   ("kuroboshi", ["★"]), ("maru1", ["①"]), ("maruichi", ["①"]),
                                   ("まる1", ["①"]), ("maru2", ["②"]), ("yajirushi", ["→", "←", "↑", "↓"]),
                                   ("mugendai", ["∞"])] {
            let result = dictionary.supplement(.init(candidates: ["LLM"]), source: reading)
            for symbol in symbols { XCTAssertTrue(result.candidates.contains(symbol), "\(reading): \(symbol)") }
            XCTAssertLessThanOrEqual(result.dictionaryCandidates.count, 10)
            XCTAssertEqual(result.candidates.first, "LLM")
        }
    }
}
