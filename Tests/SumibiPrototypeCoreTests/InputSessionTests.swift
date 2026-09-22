import XCTest
@testable import SumibiPrototypeCore

final class InputSessionTests: XCTestCase {
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
}
