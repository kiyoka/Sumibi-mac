import XCTest
import SumibiPrototypeCore
@testable import SumibiPrototypeIME

final class TextReplacementTrackerTests: XCTestCase {
    func testAcceptsCaretOrSelectionOverTheRecordedText() {
        let document = ReplacementDocument("prefix日本語", selection: NSRange(location: 9, length: 0))
        let tracker = TextReplacementTracker()
        tracker.anchor = ReplacementAnchor(end: 9, text: "日本語")
        XCTAssertTrue(tracker.validatesAnchor(in: document.input, expected: "日本語"))
        document.selection = NSRange(location: 6, length: 3)
        XCTAssertTrue(tracker.validatesAnchor(in: document.input, expected: "日本語"))
    }

    func testRejectsDifferentTextAndUnreadableText() {
        let document = ReplacementDocument("abd", selection: NSRange(location: 3, length: 0))
        let tracker = TextReplacementTracker()
        tracker.anchor = ReplacementAnchor(end: 3, text: "abc")
        XCTAssertFalse(tracker.validatesAnchor(in: document.input, expected: "abc"))
        document.text = "abc"
        document.canRead = false
        XCTAssertFalse(tracker.validatesAnchor(in: document.input, expected: "abc"))
        XCTAssertEqual(tracker.anchor?.end, 3)
    }

    func testCaretLagReanchorsOnlyWhenTheWrittenSourceMatches() {
        let (tracker, request) = pendingFirst(source: "abc", caret: 0)
        let document = ReplacementDocument("abc", selection: NSRange(location: 3, length: 0))
        tracker.reanchorIfCaretLagged(request, in: document.input)
        XCTAssertEqual(tracker.anchor?.range, NSRange(location: 0, length: 3))
        XCTAssertTrue(tracker.validatesPendingTarget(request, in: document.input))

        let (mismatch, sameRequest) = pendingFirst(source: "abc", caret: 0)
        document.text = "abd"
        mismatch.reanchorIfCaretLagged(sameRequest, in: document.input)
        XCTAssertEqual(mismatch.anchor?.end, 0)
        XCTAssertFalse(mismatch.validatesPendingTarget(sameRequest, in: document.input))
    }

    func testWrappedSourceCanMoveToTheNewCaretWithoutChangingExpectedText() {
        let (tracker, request) = pendingFirst(source: "abc def", caret: 7)
        let document = ReplacementDocument("abc\n def", selection: NSRange(location: 8, length: 0))
        tracker.reanchorAtCaret(request, in: document.input)
        XCTAssertEqual(tracker.anchor?.range, NSRange(location: 0, length: 8))
        XCTAssertEqual(tracker.anchor?.text, "abc def")
        XCTAssertTrue(tracker.validatesPendingTarget(request, in: document.input))
    }

    func testUTF16AnchorIncludesSurrogatePairs() {
        let document = ReplacementDocument("😀abc", selection: NSRange(location: 5, length: 0))
        let tracker = TextReplacementTracker()
        tracker.anchor = ReplacementAnchor(end: 5, text: "😀abc")
        XCTAssertEqual(tracker.anchor?.range.length, 5)
        XCTAssertTrue(tracker.validatesAnchor(in: document.input, expected: "😀abc"))
    }

    func testSelectionChangePreventsPendingReplacement() {
        let session = InputSession()
        _ = session.convertSelection("abc")
        let request = session.pending!
        let tracker = TextReplacementTracker()
        tracker.anchor = ReplacementAnchor(end: 3, text: "abc")
        tracker.pendingTarget = PendingTarget(requestID: request.id, selection: NSRange(location: 3, length: 0),
                                             expectedText: "abc", kind: .selection)
        let document = ReplacementDocument("abc", selection: NSRange(location: 0, length: 3))
        XCTAssertFalse(tracker.validatesPendingTarget(request, in: document.input))
    }

    func testWrongRequestIDOrKindCannotValidateOrReanchor() {
        let (tracker, request) = pendingFirst(source: "abc", caret: 3)
        let document = ReplacementDocument("abc", selection: NSRange(location: 3, length: 0))
        tracker.pendingTarget = PendingTarget(requestID: request.id + 1, selection: document.selection,
                                             expectedText: "abc", kind: .first)
        XCTAssertFalse(tracker.validatesPendingTarget(request, in: document.input))
        tracker.reanchorAtCaret(request, in: document.input)
        XCTAssertEqual(tracker.pendingTarget?.requestID, request.id + 1)
        tracker.pendingTarget = PendingTarget(requestID: request.id, selection: document.selection,
                                             expectedText: "abc", kind: .selection)
        XCTAssertFalse(tracker.validatesPendingTarget(request, in: document.input))
    }

    func testReadingLimitDoesNotAuthorizeAnUnverifiedLongReplacement() {
        let source = String(repeating: "a", count: 114)
        let (tracker, request) = pendingFirst(source: source, caret: 114)
        let document = ReplacementDocument(source, selection: NSRange(location: 114, length: 0))
        document.minimumReadableLocation = 14
        XCTAssertFalse(tracker.validatesPendingTarget(request, in: document.input))
        tracker.reanchorAtCaret(request, in: document.input)
        XCTAssertFalse(tracker.validatesPendingTarget(request, in: document.input))
    }

    private func pendingFirst(source: String, caret: Int) -> (TextReplacementTracker, PendingRequest) {
        let session = InputSession()
        _ = session.receive(.text(source))
        _ = session.receive(.convert)
        let request = session.pending!
        let tracker = TextReplacementTracker()
        tracker.anchor = ReplacementAnchor(end: caret, text: source)
        tracker.pendingTarget = PendingTarget(requestID: request.id, selection: NSRange(location: caret, length: 0),
                                             expectedText: source, kind: .first)
        return (tracker, request)
    }
}

private final class ReplacementDocument {
    var text: String
    var selection: NSRange
    var canRead = true
    var minimumReadableLocation = 0

    init(_ text: String, selection: NSRange) { self.text = text; self.selection = selection }

    var input: ReplacementInput {
        ReplacementInput(selectedRange: { self.selection }, substring: { range in
            let text = self.text as NSString
            guard self.canRead, range.location >= self.minimumReadableLocation,
                  range.location <= text.length, range.length <= text.length - range.location else { return nil }
            return text.substring(with: range)
        })
    }
}
