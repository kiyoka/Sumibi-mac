import XCTest
import AppKit
import SumibiPrototypeCore
@testable import SumibiPrototypeIME

final class InputEffectApplierTests: XCTestCase {
    func testMarkedTextAndOriginalCommitUseTheExplicitClient() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let applier = applier(runtime)
        XCTAssertTrue(applier.apply(runtime.state.receive(.text("😀abc")), to: input))
        XCTAssertEqual(input.text, "😀abc")
        XCTAssertEqual(input.markedRange(), NSRange(location: 0, length: 5))
        XCTAssertEqual(input.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(runtime.candidates.lastLineRect, input.rect)
        XCTAssertTrue(applier.apply([.commit("😀abc")], to: input))
        XCTAssertEqual(input.text, "😀abc") // No duplicate of the marked original.
        XCTAssertEqual(input.markedRange().location, NSNotFound)
    }

    func testFirstRequestCommitsOriginalAndRecordsCoordinatesBeforeStarting() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        var request: ConversionRequest?
        let applier = applier(runtime) { id, value in
            XCTAssertEqual(input.text, "abc")
            XCTAssertTrue(runtime.originalCommitted)
            XCTAssertEqual(runtime.replacement.pendingTarget?.requestID, id)
            request = value
        }
        _ = applier.apply(runtime.state.receive(.text("abc")), to: input)
        _ = applier.apply(runtime.state.receive(.convert), to: input)
        XCTAssertEqual(request, ConversionRequest(source: "abc"))
        XCTAssertEqual(runtime.replacement.anchor?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(input.text, "abc")
    }

    func testReplacementUsesWrittenRangeEvenWhenClientReturnsStaleCaret() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "abc")
        runtime.replacement.anchor = ReplacementAnchor(end: 3, text: "abc")
        input.updateCaretAfterWrite = false
        _ = applier(runtime).apply([.replacePrevious(from: "abc", to: "日本語です")], to: input)
        XCTAssertEqual(input.text, "日本語です")
        XCTAssertEqual(input.selectedRange().location, 3)
        XCTAssertEqual(runtime.replacement.anchor?.end, 5)
        XCTAssertEqual(input.writes, ["insert"])
    }

    func testMismatchUnreadableTextOrMovedCaretCannotWrite() {
        for scenario in 0..<3 {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: scenario == 0 ? "xyz" : "abc")
            runtime.replacement.anchor = ReplacementAnchor(end: 3, text: "abc")
            if scenario == 1 { input.canRead = false }
            if scenario == 2 { input.selection = NSRange(location: 0, length: 0) }
            _ = applier(runtime).apply([.replacePrevious(from: "abc", to: "結果")], to: input)
            XCTAssertTrue(input.writes.isEmpty)
            XCTAssertEqual(input.text, scenario == 0 ? "xyz" : "abc")
        }
    }

    func testSelectionConversionLeavesSurroundingTextUntouched() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix abc suffix")
        input.selection = NSRange(location: 7, length: 3)
        runtime.selectionRange = input.selection
        var started = false
        let applier = applier(runtime) { _, _ in started = true }
        _ = applier.apply(runtime.state.convertSelection("abc"), to: input)
        XCTAssertTrue(started)
        XCTAssertEqual(input.text, "prefix abc suffix")
        XCTAssertEqual(runtime.replacement.anchor?.range, NSRange(location: 7, length: 3))
        XCTAssertEqual(runtime.replacement.pendingTarget?.kind, .selection)
        _ = applier.apply([.replacePrevious(from: "abc", to: "日本語")], to: input)
        XCTAssertEqual(input.text, "prefix 日本語 suffix")
    }

    func testEscapeRemovesMarkedModeWithoutDeletingOrInsertingEnter() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let applier = applier(runtime)
        _ = applier.apply(runtime.state.receive(.text("abc")), to: input)
        _ = applier.apply(runtime.cancelComposition(), to: input)
        XCTAssertEqual(input.text, "abc")
        XCTAssertEqual(input.markedRange().location, NSNotFound)
        XCTAssertNil(runtime.replacement.anchor)
        XCTAssertTrue(runtime.state.marked.isEmpty)
        XCTAssertFalse(applier.apply(runtime.state.receive(.cancel), to: input))
    }

    func testEscapeDuringPendingRequestRescuesQueuedTextButNeverRunsControls() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let applier = applier(runtime)
        _ = applier.apply(runtime.state.receive(.text("abc")), to: input)
        _ = applier.apply(runtime.state.receive(.convert), to: input)
        let id = runtime.state.pending!.id
        _ = runtime.state.receive(.text("queued"))
        _ = runtime.state.receive(.enter)
        _ = applier.apply(runtime.cancelComposition(), to: input)
        XCTAssertEqual(input.text, "abc")
        XCTAssertEqual(runtime.rescuedText, "queued")
        XCTAssertTrue(runtime.deferredControls.isEmpty)
        XCTAssertNil(runtime.state.pending)
        XCTAssertNil(runtime.replacement.pendingTarget)
        let writesBeforeLateResponse = input.writes
        _ = applier.apply(runtime.state.completeFirst(id: id, result: "遅延結果"), to: input)
        XCTAssertEqual(input.writes, writesBeforeLateResponse)
    }

    func testTargetChangeNeverWritesTheOldResultIntoTheNewClient() {
        let runtime = isolatedRuntime()
        let oldInput = RecordingInputClient()
        let newInput = RecordingInputClient(text: "unrelated")
        let applier = applier(runtime)
        _ = applier.apply(runtime.state.receive(.text("abc")), to: oldInput)
        _ = applier.apply(runtime.state.receive(.convert), to: oldInput)
        let id = runtime.state.pending!.id
        _ = runtime.state.receive(.text("queued"))
        runtime.cancelForTargetChange()
        _ = applier.apply(runtime.state.completeFirst(id: id, result: "結果"), to: newInput)
        XCTAssertEqual(oldInput.text, "abc")
        XCTAssertEqual(newInput.text, "unrelated")
        XCTAssertTrue(newInput.writes.isEmpty)
        XCTAssertEqual(runtime.rescuedText, "queued") // Original was already committed.
        XCTAssertNil(runtime.replacement.anchor)
    }

    func testDeferredControlsAreReportedInsteadOfDelivered() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let applier = applier(runtime)
        XCTAssertTrue(applier.apply([.passEnter(deferred: true), .passBackspace(deferred: true), .passConvert(deferred: true)], to: input))
        XCTAssertEqual(runtime.deferredControls, ["Enter", "Backspace", "Control-J"])
        XCTAssertTrue(input.writes.isEmpty)
        XCTAssertFalse(applier.apply([.passEnter(deferred: false)], to: input))
        XCTAssertFalse(applier.apply([.passBackspace(deferred: false)], to: input))
        XCTAssertFalse(applier.apply([.passConvert(deferred: false)], to: input))
        XCTAssertFalse(applier.apply([.passCancel], to: input))
    }

    private func isolatedRuntime() -> PrototypeRuntime {
        let runtime = PrototypeRuntime() // Never uses .shared.
        runtime.candidates = CandidatePresenter(window: RecordingEffectWindow())
        return runtime
    }
    private func applier(_ runtime: PrototypeRuntime,
                         start: @escaping (Int, ConversionRequest) -> Void = { _, _ in }) -> InputEffectApplier {
        InputEffectApplier(runtime: runtime, startConversion: start, pokeClient: { _ in }, selectCandidate: { _ in })
    }
}

private final class RecordingInputClient: InputClient {
    var text: String
    var selection: NSRange
    private var marked = NSRange(location: NSNotFound, length: 0)
    var updateCaretAfterWrite = true
    var canRead = true
    var writes: [String] = []
    let rect = NSRect(x: 10, y: 20, width: 100, height: 20)
    init(text: String = "") { self.text = text; selection = NSRange(location: text.utf16.count, length: 0) }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { marked }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        let value = text as NSString
        guard canRead, range.location <= value.length, range.length <= value.length - range.location else { return nil }
        return NSAttributedString(string: value.substring(with: range))
    }
    func insertText(_ text: Any, replacementRange: NSRange) {
        let value = string(text)
        let range = target(replacementRange)
        self.text = (self.text as NSString).replacingCharacters(in: range, with: value)
        marked = NSRange(location: NSNotFound, length: 0)
        if updateCaretAfterWrite { selection = NSRange(location: range.location + value.utf16.count, length: 0) }
        writes.append("insert")
    }
    func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange) {
        let value = string(text)
        let range = target(replacementRange)
        self.text = (self.text as NSString).replacingCharacters(in: range, with: value)
        marked = NSRange(location: range.location, length: value.utf16.count)
        selection = NSRange(location: range.location + selectionRange.location, length: selectionRange.length)
        writes.append("marked")
    }
    func lineRect(at index: Int) -> NSRect { rect }
    private func target(_ range: NSRange) -> NSRange {
        range.location != NSNotFound ? range : (marked.location != NSNotFound ? marked : selection)
    }
    private func string(_ value: Any) -> String { (value as? NSAttributedString)?.string ?? (value as! String) }
}

private final class RecordingEffectWindow: CandidateDisplaying {
    var onSelect: ((Int) -> Void)?
    var isVisible = false
    var selectedIndex = 0
    var count = 0
    func show(candidates: [String], dictionaryCandidates: Set<String>, selected: Int, topLeft: NSPoint) { count = candidates.count; isVisible = true }
    func move(by delta: Int) { selectedIndex += delta }
    func reshow() { isVisible = true }
    func hide() { isVisible = false }
}
