import XCTest
@testable import SumibiCore

final class InputSessionTests: XCTestCase {
    func testEscapeCommitsOriginalWithoutEnterAndStartsFreshTracking() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        XCTAssertEqual(session.receive(.cancel), [.commit("abc")])
        XCTAssertTrue(session.marked.isEmpty)
        XCTAssertNil(session.previous)
        XCTAssertEqual(session.receive(.text("def")), [.marked("def")])
        XCTAssertEqual(session.receive(.convert), [.startFirst(id: 1, source: "def")])
    }

    func testEscapeWithoutTargetPassesThrough() {
        XCTAssertEqual(InputSession().receive(.cancel), [.passCancel])
    }

    func testEscapeCancelsRequestAndRescuesQueuedTextWithoutExecutingControls() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.receive(.text("xyz"))
        _ = session.receive(.enter)
        _ = session.receive(.backspace)
        _ = session.receive(.convert)
        XCTAssertEqual(session.cancelComposition(originalCommitted: true), [.rescueText("xyz")])
        XCTAssertNil(session.pending)
        XCTAssertTrue(session.marked.isEmpty)
        XCTAssertTrue(session.queuedKeys.isEmpty)
        XCTAssertEqual(session.completeFirst(id: 1, result: "遅延結果"), [])
        _ = session.receive(.text("new"))
        XCTAssertEqual(session.receive(.convert), [.startFirst(id: 2, source: "new")])
        XCTAssertEqual(session.completeFirst(id: 1, result: "遅延結果"), [])
        XCTAssertEqual(session.pending?.id, 2)
    }

    func testEscapeBeforeOriginalCommitKeepsOriginal() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        XCTAssertEqual(session.receive(.cancel), [.commit("abc")])
        XCTAssertEqual(session.completeFirst(id: 1, result: "遅延結果"), [])
    }

    func testEscapeCancelsSelectionRequestWithoutWritingSelectionAgain() {
        let session = InputSession()
        _ = session.convertSelection("abc")
        XCTAssertEqual(session.cancelComposition(originalCommitted: true), [])
        XCTAssertEqual(session.completeSelection(id: 1, result: "遅延結果"), [])
    }

    func testEscapeCancelsAlternativesAndLeavesCommittedResultAlone() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.completeFirst(id: 1, result: "第一")
        _ = session.receive(.convert, canReplacePrevious: true)
        XCTAssertEqual(session.receive(.cancel), [])
        XCTAssertNil(session.previous)
        XCTAssertEqual(session.completeAlternatives(id: 2, alternatives: ["第二"]), [])
        XCTAssertTrue(session.candidateStrings.isEmpty)
    }

    func testFirstResultCommitsBeforeQueuedText() {
        let session = InputSession()
        XCTAssertEqual(session.receive(.text("ohayou")), [.marked("ohayou")])
        XCTAssertEqual(session.receive(.convert), [.startFirst(id: 1, source: "ohayou")])
        XCTAssertEqual(session.receive(.text("gozaimasu")), [])
        XCTAssertEqual(session.completeFirst(id: 1, result: "おはよう"),
                       [.commit("おはよう"), .marked("gozaimasu")])
    }

    func testSecondConvertWaitsForItsOwnResponse() {
        let session = InputSession()
        _ = session.receive(.text("ohayou"))
        _ = session.receive(.convert)
        _ = session.receive(.convert)
        _ = session.receive(.text("x"))
        XCTAssertEqual(session.completeFirst(id: 1, result: "おはよう"),
                       [.commit("おはよう"), .startAlternatives(id: 2, source: "ohayou", current: "おはよう")])
        XCTAssertEqual(session.queuedKeys, [.text("x")])
        XCTAssertEqual(session.completeAlternatives(id: 2, alternatives: ["お早う"]), [.marked("x")])
    }

    func testFailureKeepsOriginalThenDrainsKeysInOrder() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.receive(.text("d"))
        _ = session.receive(.backspace)
        _ = session.receive(.enter)
        XCTAssertEqual(session.completeFirst(id: 1, result: nil),
                       [.marked("abcd"), .marked("abc"), .commit("abc"), .passEnter(deferred: true)])
    }

    func testTargetChangeRescuesMarkedAndQueuedTextAndDropsLateResponse() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.receive(.text("xyz"))
        _ = session.receive(.enter)
        XCTAssertEqual(session.cancelForTargetChange(), [.rescueText("abcxyz")])
        XCTAssertEqual(session.completeFirst(id: 1, result: "変換"), [])
    }

    func testCommitBeforeTargetChangeDoesNotRescueOriginalTwice() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.receive(.text("xyz"))
        XCTAssertEqual(session.cancelForTargetChange(rescueMarked: false), [.rescueText("xyz")])
    }

    func testCandidateReplacementRequiresVerifiedTarget() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.completeFirst(id: 1, result: "第一")
        _ = session.receive(.convert, canReplacePrevious: true)
        _ = session.completeAlternatives(id: 2, alternatives: ["第二"])
        XCTAssertEqual(session.chooseCandidate("第二", canReplacePrevious: false), [])
        XCTAssertEqual(session.chooseCandidate("第二", canReplacePrevious: true),
                       [.replacePrevious(from: "第一", to: "第二")])
    }

    func testCyclingCandidatesKeepsTheList() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.completeFirst(id: 1, result: "第一")
        _ = session.receive(.convert, canReplacePrevious: true)
        _ = session.completeAlternatives(id: 2, alternatives: ["第二", "第三"])
        XCTAssertEqual(session.chooseCandidate("第二", canReplacePrevious: true, keepCandidates: true),
                       [.replacePrevious(from: "第一", to: "第二")])
        XCTAssertEqual(session.candidateStrings, ["第一", "第二", "第三"])
        XCTAssertEqual(session.chooseCandidate("第一", canReplacePrevious: true, keepCandidates: true),
                       [.replacePrevious(from: "第二", to: "第一")])
        XCTAssertEqual(session.previous?.result, "第一")
    }

    func testConvertPressedAgainWhileFetchingCandidatesStillShowsThem() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.completeFirst(id: 1, result: "第一")
        _ = session.receive(.convert, canReplacePrevious: true)
        XCTAssertEqual(session.receive(.convert, canReplacePrevious: true), [])
        XCTAssertEqual(session.queuedKeys, [])
        XCTAssertEqual(session.completeAlternatives(id: 2, alternatives: ["第二"]),
                       [.showCandidates(["第一", "第二"])])
        XCTAssertNil(session.pending)
    }

    func testConvertPressesQueuedDuringFirstRequestDoNotRepeatCandidateFetch() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.receive(.convert)
        _ = session.receive(.convert)
        _ = session.receive(.convert)
        XCTAssertEqual(session.completeFirst(id: 1, result: "第一"),
                       [.commit("第一"), .startAlternatives(id: 2, source: "abc", current: "第一")])
        XCTAssertEqual(session.receive(.convert), [])
        XCTAssertEqual(session.queuedKeys, [.convert, .convert])
        XCTAssertEqual(session.completeAlternatives(id: 2, alternatives: ["第二"]),
                       [.showCandidates(["第一", "第二"])])
        XCTAssertTrue(session.queuedKeys.isEmpty)
        XCTAssertNil(session.pending)
    }

    func testConvertAfterTextTypedWhileFetchingCandidatesIsKept() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.completeFirst(id: 1, result: "第一")
        _ = session.receive(.convert, canReplacePrevious: true)
        _ = session.receive(.text("x"))
        _ = session.receive(.convert)
        XCTAssertEqual(session.queuedKeys, [.text("x"), .convert])
    }

    func testLimitRejectsRequestWithoutLosingMarkedText() {
        let session = InputSession()
        _ = session.receive(.text(String(repeating: "a", count: 1_001)))
        XCTAssertEqual(session.receive(.convert), [.overLimit])
        XCTAssertNil(session.pending)
        XCTAssertEqual(session.marked.count, 1_001)
    }

    func testExactlyOneThousandCharactersCanStartRequest() {
        let session = InputSession()
        let source = String(repeating: "あ", count: 1_000)
        _ = session.receive(.text(source))
        XCTAssertEqual(session.receive(.convert), [.startFirst(id: 1, source: source)])
    }

    func testQueuedControlJStartsNextRequestWithoutOvertakingLaterKeys() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.receive(.text("def"))
        _ = session.receive(.convert)
        _ = session.receive(.text("ghi"))
        XCTAssertEqual(session.completeFirst(id: 1, result: "第一"),
                       [.commit("第一"), .marked("def"), .startFirst(id: 2, source: "def")])
        XCTAssertEqual(session.queuedKeys, [.text("ghi")])
        XCTAssertEqual(session.completeFirst(id: 2, result: "第二"), [.commit("第二"), .marked("ghi")])
    }

    func testFailureIgnoresOldResponseID() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        XCTAssertEqual(session.completeFirst(id: 1, result: nil), [])
        XCTAssertEqual(session.marked, "abc")
        XCTAssertEqual(session.completeFirst(id: 1, result: "遅延結果"), [])
    }

    func testQueuedConvertAfterFailureRetriesOriginalAsUserInput() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.receive(.convert)
        _ = session.receive(.text("xyz"))
        XCTAssertEqual(session.completeFirst(id: 1, result: nil),
                       [.startFirst(id: 2, source: "abc")])
        XCTAssertEqual(session.queuedKeys, [.text("xyz")])
        XCTAssertEqual(session.completeFirst(id: 2, result: "変換"),
                       [.commit("変換"), .marked("xyz")])
    }

    func testSelectionConversionReplacesTheSelectedText() {
        let session = InputSession()
        XCTAssertEqual(session.convertSelection("ohayou"), [.startSelection(id: 1, source: "ohayou")])
        XCTAssertEqual(session.completeSelection(id: 1, result: "おはよう"),
                       [.replacePrevious(from: "ohayou", to: "おはよう")])
        // 変換後は同じ位置での追加候補に進める。
        XCTAssertEqual(session.receive(.convert, canReplacePrevious: true),
                       [.startAlternatives(id: 2, source: "ohayou", current: "おはよう")])
    }

    func testFailedSelectionConversionLeavesTheDocumentAlone() {
        let session = InputSession()
        _ = session.convertSelection("ohayou")
        XCTAssertEqual(session.completeSelection(id: 1, result: nil), [])
        XCTAssertNil(session.previous)
        XCTAssertEqual(session.marked, "")
    }

    func testKeysTypedDuringSelectionConversionApplyAfterwards() {
        let session = InputSession()
        _ = session.convertSelection("ohayou")
        XCTAssertEqual(session.receive(.text("a")), [])
        XCTAssertEqual(session.completeSelection(id: 1, result: "おはよう"),
                       [.replacePrevious(from: "ohayou", to: "おはよう"), .marked("a")])
    }

    func testSelectionIsNotConvertedWhileSomethingElseIsPending() {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        XCTAssertEqual(session.convertSelection("ohayou"), [])
    }

    func testSelectionOverTheLimitIsRejected() {
        let session = InputSession()
        XCTAssertEqual(session.convertSelection(String(repeating: "a", count: 1_001)), [.overLimit])
        XCTAssertNil(session.pending)
    }
}
