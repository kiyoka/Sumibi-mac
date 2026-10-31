import XCTest
import AppKit
import SumibiCore
@testable import SumibiIME

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

    func testNavigationCommitsOriginalBeforeClientCanDiscardComposition() {
        // Model the reported client behavior: a forwarded arrow drops composition.
        let unprotected = RecordingInputClient(text: "prefix ")
        unprotected.setMarkedText("nihongo", selectionRange: NSRange(location: 7, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        unprotected.passLeftArrowDiscardingComposition()
        XCTAssertEqual(unprotected.text, "prefix ")

        for code: UInt16 in [123, 124, 125, 126, 115, 119, 116, 121] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: "prefix suffix")
            input.selection = NSRange(location: 7, length: 0)
            let effects = applier(runtime)
            _ = effects.apply(runtime.state.receive(.text("nihongo")), to: input)
            XCTAssertTrue(InputRuntime.isNavigationKey(code))
            let navigation = runtime.prepareForNavigation(keyCode: code)
            XCTAssertEqual(navigation, [.commit("nihongo")])
            _ = effects.apply(navigation!, to: input)
            // The client can now move without dropping the original.
            input.passLeftArrowDiscardingComposition()
            XCTAssertEqual(input.text, "prefix nihongosuffix")
            XCTAssertEqual(input.selection, NSRange(location: 13, length: 0))
            XCTAssertEqual(input.insertedValues, ["nihongo"])
            XCTAssertTrue(runtime.state.marked.isEmpty)
            XCTAssertNil(runtime.state.previous)
            XCTAssertNil(runtime.replacement.anchor)
        }
    }

    func testNavigationDoesNotDuplicateCommittedOriginalOrExecuteQueuedControls() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let effects = applier(runtime)
        _ = effects.apply(runtime.state.receive(.text("nihongo")), to: input)
        _ = effects.apply(runtime.state.receive(.convert), to: input)
        let id = runtime.state.pending!.id
        _ = runtime.state.receive(.text("next"))
        _ = runtime.state.receive(.enter)
        _ = effects.apply(runtime.prepareForNavigation(keyCode: 123)!, to: input)
        input.passLeftArrowDiscardingComposition()
        XCTAssertEqual(input.text, "nihongo")
        XCTAssertEqual(input.insertedValues, ["nihongo"])
        XCTAssertEqual(runtime.rescuedText, "next")
        XCTAssertTrue(runtime.deferredControls.isEmpty)
        XCTAssertNil(runtime.state.pending)
        XCTAssertNil(runtime.replacement.pendingTarget)
        let writes = input.writes
        _ = effects.apply(runtime.state.completeFirst(id: id, result: "late"), to: input)
        XCTAssertEqual(input.writes, writes)
    }

    func testNavigationKeepsCandidateArrowsAndNonNavigationKeysUnchanged() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        _ = applier(runtime).apply(runtime.state.receive(.text("nihongo")), to: input)
        for code: UInt16? in [nil, 0, 36, 51, 53, 54, 104] {
            XCTAssertFalse(InputRuntime.isNavigationKey(code))
            XCTAssertNil(runtime.prepareForNavigation(keyCode: code))
        }
        runtime.candidates.show(candidates: ["日本語", "にほんご"], topLeft: .zero, onSelect: { _ in })
        for code: UInt16 in [123, 124, 125, 126] {
            XCTAssertNil(runtime.prepareForNavigation(keyCode: code))
        }
        XCTAssertTrue(runtime.candidates.shouldBeVisible)
        XCTAssertEqual(runtime.state.marked, "nihongo")
        XCTAssertTrue(input.insertedValues.isEmpty)
    }

    func testNavigationAfterConversionDoesNotReinsertOrRetainReplacementTarget() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        _ = applier(runtime).apply(runtime.state.receive(.text("nihongo")), to: input)
        XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["日本語"]), to: input))
        let writes = input.writes
        _ = applier(runtime).apply(runtime.prepareForNavigation(keyCode: 123)!, to: input)
        input.passLeftArrowDiscardingComposition()
        XCTAssertEqual(input.text, "日本語")
        XCTAssertEqual(input.writes, writes)
        XCTAssertNil(runtime.state.previous)
        XCTAssertNil(runtime.replacement.anchor)
    }

    @MainActor
    func testNavigationCancelsReadyManualResultBeforeItCanBeFlushed() async throws {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        runtime.conversion = ConversionLifecycle(session: runtime.state, convert: { _ in
            .success(ConversionResult(candidates: ["日本語"]))
        })
        let effects = applier(runtime) { id, request in
            runtime.conversion.start(id: id, request: request, onReady: { _ in })
        }
        _ = effects.apply(runtime.state.receive(.text("nihongo")), to: input)
        _ = effects.apply(runtime.state.receive(.convert), to: input)
        let id = runtime.state.pending!.id
        for _ in 0..<100 where runtime.conversion.readyAt == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(runtime.conversion.readyAt)
        _ = effects.apply(runtime.prepareForNavigation(keyCode: 123)!, to: input)
        input.passLeftArrowDiscardingComposition()
        XCTAssertNil(runtime.conversion.takeOutcome(id: id))
        XCTAssertNil(runtime.state.pending)
        XCTAssertEqual(input.text, "nihongo")
        XCTAssertEqual(input.insertedValues, ["nihongo"])
    }

    @MainActor
    func testNavigationCancelsCollectedOrInFlightDecisionAndPreservesOriginal() async throws {
        for inFlight in [false, true] {
            let name = "org.sumibi.tests.navigation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let store = DecisionsSettingsStore(defaults: defaults)
            var settings = DecisionsSettings()
            settings.enabled = true; settings.consent = true
            settings.batchWindowMilliseconds = inFlight ? 0 : 1_000
            try store.save(settings)
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: "prefix ")
            let effects = applier(runtime)
            _ = effects.apply(runtime.state.receive(.text("nihongo")), to: input)
            let gate = NavigationScoreGate()
            var converted = false
            var applied = false
            runtime.ambient = AmbientConversionLifecycle(store: store, feedback: runtime.feedback,
                prepare: { _, _ in AmbientWork(score: { _ in await gate.score() }, convert: {
                    converted = true
                    return .success(ConversionResult(candidates: ["日本語"]))
                }, remainsAuthorized: { true }) })
            runtime.ambient.observe(.init(observation: DecisionsObservation(text: "nihongo", latestKey: "o")!,
                isCurrent: { runtime.state.marked == "nihongo" }, apply: { _ in applied = true; return true }))
            if inFlight {
                for _ in 0..<100 {
                    if await gate.started { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let started = await gate.started
                XCTAssertTrue(started)
            }
            _ = effects.apply(runtime.prepareForNavigation(keyCode: 123)!, to: input)
            input.passLeftArrowDiscardingComposition()
            if inFlight { await gate.finish() }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(runtime.ambient.phase, .idle)
            XCTAssertEqual(store.calls, inFlight ? 1 : 0)
            XCTAssertFalse(converted); XCTAssertFalse(applied)
            XCTAssertNil(runtime.feedback.notice)
            XCTAssertEqual(input.text, "prefix nihongo")
            XCTAssertEqual(input.insertedValues, ["nihongo"])
            XCTAssertTrue(runtime.state.marked.isEmpty)
        }
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

    func testAmbientPreparedResultKeepsPrefixCommitsOriginalAndRecordsPrevious() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "前置 ")
        _ = applier(runtime).apply(runtime.state.receive(.text("nihongo ")), to: input)
        XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["日本語"]), to: input))
        XCTAssertEqual(input.text, "前置 日本語")
        XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
        XCTAssertEqual(runtime.state.marked, "")
        XCTAssertNil(runtime.state.pending)
        XCTAssertTrue(runtime.state.queuedKeys.isEmpty)
        XCTAssertEqual(runtime.state.previous?.source, "nihongo ")
        XCTAssertEqual(runtime.state.previous?.result, "日本語")
        XCTAssertTrue(runtime.replacement.validatesAnchor(in: ReplacementInput(input), expected: "日本語"))
    }

    func testAmbientInputSnapshotUsesUTF16AndRejectsUnreadableMovedOrSelectedText() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix ")
        _ = applier(runtime).apply(runtime.state.receive(.text("😀abc")), to: input)
        let snapshot = AmbientInputSnapshot(source: "😀abc", input: input)
        XCTAssertEqual(snapshot?.marked.length, 5)
        XCTAssertTrue(snapshot?.matches(input) ?? false)
        input.selection = NSRange(location: 0, length: 1)
        XCTAssertNil(AmbientInputSnapshot(source: "😀abc", input: input))
        XCTAssertFalse(snapshot?.matches(input) ?? true)
        input.selection = NSRange(location: 12, length: 0)
        input.canRead = false
        XCTAssertNil(AmbientInputSnapshot(source: "😀abc", input: input))
    }

    func testAmbientDeliveryCannotTouchMismatchUnreadableOrEmptyResult() {
        for scenario in 0..<4 {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient()
            _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
            if scenario == 0 { input.canRead = false }
            if scenario == 1 { input.selection = NSRange(location: 1, length: 0) }
            if scenario == 2 { input.text = "xyz" }
            input.writes = []
            let result = ConversionResult(candidates: scenario == 3 ? [] : ["結果"])
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(result, to: input))
            XCTAssertTrue(input.writes.isEmpty)
            XCTAssertNil(runtime.state.pending)
            XCTAssertEqual(runtime.state.marked, "abc")
        }
    }

    func testAmbientSnapshotReportsFixedReasonWithoutInputPayload() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        func reason() -> AmbientObservationBlock? {
            if case .failure(let error) = AmbientInputSnapshot.capture(source: "secretInput", input: input) {
                return error
            }
            return nil
        }
        XCTAssertEqual(reason(), .markedUnavailable)
        _ = applier(runtime).apply(runtime.state.receive(.text("secretInput")), to: input)
        if case .failure = AmbientInputSnapshot.capture(source: "secretInput", input: input) {
            XCTFail("Valid input must remain eligible")
        }
        input.selection.length = 1
        XCTAssertEqual(reason(), .selectionMismatch)
        input.selection.length = 0
        input.canRead = false
        XCTAssertEqual(reason(), .sourceUnavailable)
        input.canRead = true
        input.text = "otherInput!"
        XCTAssertEqual(reason(), .sourceMismatch)
        if case .failure(let error) = AmbientInputSnapshot.capture(source: "short", input: input) {
            XCTAssertEqual(error, .markedLengthMismatch)
        } else { XCTFail("Mismatched length must be rejected") }
        for reason in AmbientObservationBlock.allCases {
            XCTAssertFalse(reason.rawValue.contains("secretInput"))
            XCTAssertFalse(reason.rawValue.contains("otherInput"))
        }
    }

    func testAmbientDeliveryCannotInterruptManualPendingRequest() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
        _ = runtime.state.receive(.convert)
        input.writes = []
        XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]), to: input))
        XCTAssertTrue(input.writes.isEmpty)
        XCTAssertNotNil(runtime.state.pending)
    }

    func testAmbientAcceptsWholeCompositionSelectionAndPreservesPrefixOnDelivery() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix ")
        input.reportsMarkedAsSelection = true
        _ = applier(runtime).apply(runtime.state.receive(.text("nihongo.")), to: input)
        let snapshot = AmbientInputSnapshot(source: "nihongo.", input: input)
        XCTAssertEqual(snapshot?.selection, input.markedRange())
        XCTAssertTrue(snapshot?.matches(input) ?? false)
        XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["日本語。"]), to: input))
        XCTAssertEqual(input.text, "prefix 日本語。")
        XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
        XCTAssertEqual(runtime.state.previous?.source, "nihongo.")
        XCTAssertNil(runtime.state.pending)
    }

    func testAmbientStillRejectsPartialOutsideUnknownSelectionAndChangedSelectionConvention() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix ")
        _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
        input.reportsMarkedAsSelection = true
        let snapshot = AmbientInputSnapshot(source: "abc", input: input)
        XCTAssertNotNil(snapshot)
        input.reportsMarkedAsSelection = false
        XCTAssertFalse(snapshot?.matches(input) ?? true)
        for range in [NSRange(location: 7, length: 2), NSRange(location: 0, length: 3),
                      NSRange(location: 7, length: 0), NSRange(location: NSNotFound, length: 0)] {
            input.selection = range
            XCTAssertNil(AmbientInputSnapshot(source: "abc", input: input))
            input.writes = []
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]), to: input))
            XCTAssertTrue(input.writes.isEmpty)
        }
        input.reportsMarkedAsSelection = true
        input.text = "prefix xyz"
        XCTAssertNil(AmbientInputSnapshot(source: "abc", input: input))
    }

    private func isolatedRuntime() -> InputRuntime {
        let runtime = InputRuntime() // Never uses .shared.
        runtime.candidates = CandidatePresenter(window: RecordingEffectWindow())
        return runtime
    }

    private func deferredSourceFixture(prefix: String = "", relative: Bool = false) throws
        -> (runtime: InputRuntime, input: RecordingInputClient, wait: AmbientSourceVerification) {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: prefix)
        input.canReadMarked = false
        input.reportsRelativeMarkedCaret = relative
        input.keepsRelativeCaretAfterCommit = relative
        _ = applier(runtime).apply(runtime.state.receive(.text("abcdefghijklmnopqr")), to: input)
        input.onInsert = { [unowned input] in
            if input.insertedValues.count == 1 { input.canRead = false }
        }
        var wait: AmbientSourceVerification?
        var failure: AmbientDeliveryFailure?
        XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["日本語"]),
            to: input, allowUnreadableComposition: true, onFailure: { failure = $0 },
            onDeferredSource: { wait = $0 }))
        XCTAssertNil(failure)
        XCTAssertEqual(input.insertedValues, ["abcdefghijklmnopqr"])
        XCTAssertEqual(runtime.awaitingAmbientSourceID, runtime.state.pending?.id)
        return (runtime, input, try XCTUnwrap(wait))
    }

    func testDelayedCommittedSourceIsReadOnlyUntilExactMatchThenReplacedOnce() throws {
        let f = try deferredSourceFixture(prefix: "prefix ")
        let applier = AmbientResultApplier(runtime: f.runtime)
        for _ in 0..<3 {
            guard case .waiting = applier.resumeSource(f.wait, to: f.input) else { return XCTFail("Must wait") }
        }
        XCTAssertEqual(f.input.writes, ["marked", "insert"])
        f.input.canRead = true
        var report: AmbientCommitReport?
        guard case .applied = applier.resumeSource(f.wait, to: f.input, onCommitReport: { report = $0 }) else {
            return XCTFail("Must apply the already prepared result")
        }
        f.wait.cancel(runtime: f.runtime) // Successful completion is not undone by cleanup.
        XCTAssertEqual(report?.originalComparison, .equal)
        XCTAssertEqual(f.input.text, "prefix 日本語")
        XCTAssertEqual(f.input.insertedValues, ["abcdefghijklmnopqr", "日本語"])
        XCTAssertEqual(f.runtime.state.previous?.source, "abcdefghijklmnopqr")
        XCTAssertEqual(f.runtime.state.previous?.result, "日本語")
        XCTAssertNil(f.runtime.state.pending)
        XCTAssertNil(f.runtime.awaitingAmbientSourceID)
        XCTAssertFalse(f.runtime.originalCommitted)
    }

    func testDelayedSourceMismatchEmptyAndPartialReadsNeverWriteAResult() throws {
        for actual in ["different", "", "abcdefghijklmnopq", "ABCDEFGHIJKLMNOPQR"] {
            let f = try deferredSourceFixture()
            f.input.canRead = true; f.input.committedReadOverride = actual
            let writes = f.input.writes
            guard case .failed(.committedSourceMismatch) = AmbientResultApplier(runtime: f.runtime)
                .resumeSource(f.wait, to: f.input) else { return XCTFail("Must reject a non-exact source") }
            f.wait.cancel(runtime: f.runtime)
            XCTAssertEqual(f.input.writes, writes)
            XCTAssertEqual(f.input.text, "abcdefghijklmnopqr")
            XCTAssertNil(f.runtime.state.pending)
            XCTAssertTrue(f.runtime.state.marked.isEmpty)
            XCTAssertNil(f.runtime.replacement.anchor)
        }
    }

    func testDelayedRelativeCaretRetainsExactRecordedRangeAndPrefix() throws {
        let prefix = String(repeating: "x", count: 22)
        let f = try deferredSourceFixture(prefix: prefix, relative: true)
        XCTAssertEqual(f.input.selectedRange(), NSRange(location: 18, length: 0))
        f.input.canRead = true
        guard case .applied = AmbientResultApplier(runtime: f.runtime).resumeSource(f.wait, to: f.input) else {
            return XCTFail("The verified old range should be used")
        }
        XCTAssertEqual(f.input.text, prefix + "日本語")
        XCTAssertEqual(f.runtime.replacement.anchor?.range, NSRange(location: 22, length: 3))
        XCTAssertEqual(f.input.insertedValues.count, 2)
    }

    func testSourceWaitCannotResumeAfterSelectionTrackingOrCandidateChanges() throws {
        for scenario in 0..<5 {
            let f = try deferredSourceFixture()
            f.input.canRead = true
            switch scenario {
            case 0: f.input.selection = NSRange(location: 17, length: 0)
            case 1: f.runtime.replacement.anchor = ReplacementAnchor(end: 19, text: "abcdefghijklmnopqr")
            case 2: f.runtime.replacement.pendingTarget = nil
            case 3: f.runtime.candidates.show(candidates: ["other"], topLeft: .zero, onSelect: { _ in })
            default: _ = f.runtime.state.receive(.text("queued"))
            }
            let writes = f.input.writes
            guard case .cancelled = AmbientResultApplier(runtime: f.runtime).resumeSource(f.wait, to: f.input) else {
                return XCTFail("Changed state must cancel before reading/applying")
            }
            f.wait.cancel(runtime: f.runtime)
            XCTAssertEqual(f.input.writes, writes)
            XCTAssertEqual(f.input.text, "abcdefghijklmnopqr")
            if scenario == 4 { XCTAssertEqual(f.runtime.rescuedText, "queued") }
        }
    }

    func testNewInputDuringSourceWaitIsNeitherQueuedNorLostAndOldCleanupIsHarmless() throws {
        let f = try deferredSourceFixture()
        f.runtime.cancelAmbientSourceWaitForInput()
        _ = applier(f.runtime).apply(f.runtime.state.receive(.text("new")), to: f.input)
        XCTAssertEqual(f.input.text, "abcdefghijklmnopqrnew")
        XCTAssertEqual(f.runtime.state.marked, "new")
        XCTAssertTrue(f.runtime.state.queuedKeys.isEmpty)
        let writes = f.input.writes
        guard case .cancelled = AmbientResultApplier(runtime: f.runtime).resumeSource(f.wait, to: f.input) else {
            return XCTFail("Old result must not be applied")
        }
        f.wait.cancel(runtime: f.runtime)
        XCTAssertEqual(f.input.writes, writes)
        XCTAssertEqual(f.runtime.state.marked, "new")
        XCTAssertNil(f.runtime.awaitingAmbientSourceID)
    }

    func testSourceWaitCancellationLetsEscapeNavigationAndControlsPassNormally() throws {
        for key in [InputKey.cancel, .backspace, .enter, .convert] {
            let f = try deferredSourceFixture()
            f.runtime.cancelAmbientSourceWaitForInput()
            XCTAssertFalse(applier(f.runtime).apply(f.runtime.state.receive(key), to: f.input))
            XCTAssertTrue(f.runtime.state.queuedKeys.isEmpty)
            XCTAssertEqual(f.input.insertedValues, ["abcdefghijklmnopqr"])
        }
        let f = try deferredSourceFixture()
        f.runtime.cancelAmbientSourceWaitForInput()
        _ = applier(f.runtime).apply(f.runtime.prepareForNavigation(keyCode: 123)!, to: f.input)
        f.input.passLeftArrowDiscardingComposition()
        XCTAssertEqual(f.input.text, "abcdefghijklmnopqr")
        XCTAssertEqual(f.input.selectedRange(), NSRange(location: 17, length: 0))
        XCTAssertEqual(f.input.insertedValues.count, 1)
    }

    func testSourceWaitCanTransitionToReadOnlyResultVerificationWithoutWritingAgain() throws {
        let f = try deferredSourceFixture()
        f.input.canRead = true
        f.input.onInsert = { [unowned input = f.input] in
            if input.insertedValues.count == 2 { input.committedReadOverride = "abcdefghijklmnopqr" }
        }
        var verification: AmbientResultVerification?
        guard case .verifyingResult = AmbientResultApplier(runtime: f.runtime).resumeSource(f.wait, to: f.input,
            onDeferredVerification: { verification = $0 }) else { return XCTFail("Must verify the written result") }
        f.wait.cancel(runtime: f.runtime)
        let writes = f.input.writes
        f.input.committedReadOverride = nil
        XCTAssertTrue(try XCTUnwrap(verification).matches(f.input))
        XCTAssertEqual(f.input.writes, writes)
        XCTAssertEqual(f.input.insertedValues, ["abcdefghijklmnopqr", "日本語"])
        XCTAssertEqual(f.runtime.state.previous?.result, "日本語")
    }

    func testInvalidPostCommitCaretCannotCreateAnUnreadableSourceWait() {
        for caret in [NSRange(location: NSNotFound, length: 0), NSRange(location: 1, length: 0), NSRange(location: 0, length: 3)] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient()
            input.canReadMarked = false
            _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
            input.onInsert = { [unowned input] in input.selection = caret; input.canRead = false }
            var deferred = false
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]),
                to: input, allowUnreadableComposition: true, onDeferredSource: { _ in deferred = true }))
            XCTAssertFalse(deferred)
            XCTAssertNil(runtime.awaitingAmbientSourceID)
            XCTAssertEqual(input.insertedValues, ["abc"])
        }
    }

    func testSourceWaitDoesNotReplaceUntilClientCompositionHasEnded() throws {
        let f = try deferredSourceFixture()
        f.input.canRead = true
        f.input.reportedCommittedMarkedRange = f.wait.snapshot.marked
        guard case .waiting = AmbientResultApplier(runtime: f.runtime).resumeSource(f.wait, to: f.input) else {
            return XCTFail("An ended composition must be confirmed before replacement")
        }
        XCTAssertEqual(f.input.insertedValues.count, 1)
        f.input.reportedCommittedMarkedRange = nil
        guard case .applied = AmbientResultApplier(runtime: f.runtime).resumeSource(f.wait, to: f.input) else {
            return XCTFail("Ended and exactly matching original should apply")
        }
        XCTAssertEqual(f.input.insertedValues, ["abcdefghijklmnopqr", "日本語"])
    }

    func testSlowSynchronousSourceReadCannotWriteAfterDeadline() throws {
        let f = try deferredSourceFixture()
        f.input.canRead = true
        var reads = 0
        f.input.onRead = {
            reads += 1
            if reads == 1 { Thread.sleep(forTimeInterval: 0.02) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.01
        guard case .failed(.committedSourceUnavailable) = AmbientResultApplier(runtime: f.runtime)
            .resumeSource(f.wait, to: f.input, deadline: deadline) else { return XCTFail("Expired reads must not write") }
        f.wait.cancel(runtime: f.runtime)
        XCTAssertEqual(f.input.insertedValues, ["abcdefghijklmnopqr"])
        XCTAssertEqual(f.input.text, "abcdefghijklmnopqr")
    }

    func testActivityOrFocusChangeDuringSourceReadCannotWrite() throws {
        let f = try deferredSourceFixture()
        f.input.canRead = true
        var authorized = true
        f.input.onRead = { authorized = false }
        guard case .cancelled = AmbientResultApplier(runtime: f.runtime)
            .resumeSource(f.wait, to: f.input, mayApply: { authorized }) else {
            return XCTFail("Activity must be checked after reading and before writing")
        }
        f.wait.cancel(runtime: f.runtime)
        XCTAssertEqual(f.input.text, "abcdefghijklmnopqr")
        XCTAssertEqual(f.input.insertedValues, ["abcdefghijklmnopqr"])
    }

    @MainActor
    func testCommittedSourceWaitWithRealApplierCompletesOrCancelsWithoutQueuedInput() async throws {
        for cancelForInput in [false, true] {
            let domain = "org.sumibi.tests.source-wait.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = DecisionsSettingsStore(defaults: defaults)
            var settings = DecisionsSettings()
            settings.enabled = true; settings.consent = true; settings.batchWindowMilliseconds = 0
            try store.save(settings)
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: "prefix ")
            input.canReadMarked = false
            _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
            input.onInsert = { [unowned input] in
                if input.insertedValues.count == 1 { input.canRead = false }
            }
            var converted = 0
            var pending: AmbientSourceVerification?
            let life = AmbientConversionLifecycle(store: store, feedback: runtime.feedback,
                prepare: { _, _ in AmbientWork(score: { _ in 1 }, convert: {
                    converted += 1; return .success(.init(candidates: ["日本語"]))
                }, remainsAuthorized: { true }) })
            runtime.ambient = life
            life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
                isCurrent: { runtime.state.marked == "abc" && runtime.state.pending == nil },
                apply: { result in
                    life.beginDeliveryAttempt()
                    return AmbientResultApplier(runtime: runtime).apply(result, to: input,
                        allowUnreadableComposition: true, onFailure: { life.recordDeliveryFailure($0) },
                        onDeferredSource: { pending = $0 })
                }, sourceContinuation: {
                    guard let pending else { return nil }
                    return .init(poll: { deadline in
                        AmbientResultApplier(runtime: runtime).resumeSource(pending, to: input, deadline: deadline)
                    }, cancel: { pending.cancel(runtime: runtime) })
                }))
            for _ in 0..<100 where life.phase != .verifyingSource {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(life.phase, .verifyingSource)
            XCTAssertEqual(input.insertedValues, ["abc"])
            if cancelForInput {
                runtime.cancelAmbientSourceWaitForInput()
                _ = applier(runtime).apply(runtime.state.receive(.text("next")), to: input)
            }
            input.canRead = true
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(life.phase, .idle)
            XCTAssertNil(runtime.awaitingAmbientSourceID)
            XCTAssertNil(runtime.state.pending)
            XCTAssertTrue(runtime.state.queuedKeys.isEmpty)
            XCTAssertEqual(input.text, cancelForInput ? "prefix abcnext" : "prefix 日本語")
            XCTAssertEqual(input.insertedValues, cancelForInput ? ["abc"] : ["abc", "日本語"])
            XCTAssertEqual(converted, 1); XCTAssertEqual(store.calls, 1)
            XCTAssertNil(runtime.feedback.notice)
        }
    }

    func testCommitTextCaptureIsExplicitAndDoesNotChangeWritesOrSafety() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: String(repeating: "x", count: 22))
        input.reportsRelativeMarkedCaret = true
        input.keepsRelativeCaretAfterCommit = true
        input.canReadMarked = false
        input.committedReadOverride = ""
        _ = applier(runtime).apply(runtime.state.receive(.text("nihongo desu.")), to: input)
        var captured: AmbientCommitTextReport?
        XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]),
            to: input, allowUnreadableComposition: true, onCommitTextReport: { captured = $0 }))
        XCTAssertEqual(captured?.source, "nihongo desu.")
        XCTAssertEqual(captured?.atOriginal, "")
        XCTAssertEqual(captured?.atCaret, "")
        XCTAssertEqual(input.writes, ["marked", "insert"])
        XCTAssertEqual(input.text, String(repeating: "x", count: 22) + "nihongo desu.")
    }

    func testResultDebugCapturesFailedImmediateReadBeforeTrackingIsCleared() {
        for actual in [nil, "", "old text"] as [String?] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient()
            _ = applier(runtime).apply(runtime.state.receive(.text("sample.")), to: input)
            input.onInsert = {
                if input.insertedValues.count == 2 {
                    if let actual { input.committedReadOverride = actual }
                    else { input.canRead = false }
                }
            }
            var report: AmbientResultTextReport?
            var failure: AmbientDeliveryFailure?
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(
                ConversionResult(candidates: ["例文。"]), to: input,
                onFailure: { failure = $0 }, onResultTextReport: { report = $0 }))
            XCTAssertEqual(failure, .resultUnavailable)
            XCTAssertEqual(report?.expected, "例文。")
            XCTAssertEqual(report?.range, NSRange(location: 0, length: 3))
            XCTAssertEqual(report?.selection, NSRange(location: 3, length: 0))
            XCTAssertEqual(report?.actual, actual)
            XCTAssertEqual(report?.atCaret, actual)
            XCTAssertEqual(report?.stateMatches, true)
            XCTAssertEqual(input.text, "例文。")
            XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
            XCTAssertNil(runtime.replacement.anchor)
        }
    }

    func testResultDebugDistinguishesCaretCoordinatesWithoutChangingDelivery() {
        for enabled in [false, true] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: "prefix ")
            _ = applier(runtime).apply(runtime.state.receive(.text("sample.")), to: input)
            input.onInsert = {
                if input.insertedValues.count == 2 { input.selection = NSRange(location: 3, length: 0) }
            }
            var report: AmbientResultTextReport?
            XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(
                ConversionResult(candidates: ["例文。"]), to: input,
                onResultTextReport: enabled ? { report = $0 } : nil))
            if enabled {
                XCTAssertEqual(report?.range, NSRange(location: 7, length: 3))
                XCTAssertEqual(report?.actual, "例文。")
                XCTAssertEqual(report?.caretRange, NSRange(location: 0, length: 3))
                XCTAssertEqual(report?.atCaret, "pre")
            } else { XCTAssertNil(report) }
            XCTAssertEqual(input.text, "prefix 例文。")
            XCTAssertEqual(input.insertedValues, ["sample.", "例文。"])
            XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
        }
    }

    func testDeferredResultVerificationWaitsWithoutRewritingOrClearingConversionState() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix ")
        _ = applier(runtime).apply(runtime.state.receive(.text("sample.")), to: input)
        input.onInsert = {
            if input.insertedValues.count == 2 {
                input.committedReadOverride = "sample."
                input.selection = NSRange(location: 14, length: 0)
            }
        }
        var verification: AmbientResultVerification?
        var failure: AmbientDeliveryFailure?
        XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(
            ConversionResult(candidates: ["例文。"]), to: input, onFailure: { failure = $0 },
            onDeferredVerification: { verification = $0 }))
        XCTAssertNil(failure)
        XCTAssertEqual(runtime.state.previous?.result, "例文。")
        XCTAssertEqual(verification?.range, NSRange(location: 7, length: 3))
        XCTAssertTrue(verification?.isCurrent(runtime: runtime, input: input) ?? false)
        XCTAssertFalse(verification?.matches(input) ?? true)
        input.committedReadOverride = nil
        input.selection = NSRange(location: 10, length: 0)
        XCTAssertTrue(verification?.isCurrent(runtime: runtime, input: input) ?? false)
        XCTAssertTrue(verification?.matches(input) ?? false)
        XCTAssertEqual(input.text, "prefix 例文。")
        XCTAssertEqual(input.insertedValues, ["sample.", "例文。"])
        XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
    }

    func testDeferredResultVerificationRejectsChangedInputStateSelectionAndComposition() {
        for scenario in 0..<5 {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: "例文。")
            _ = runtime.state.receive(.text("sample."))
            _ = runtime.state.receive(.convert)
            let id = runtime.state.pending!.id
            _ = runtime.state.completeFirst(id: id, result: "例文。")
            runtime.replacement.anchor = ReplacementAnchor(end: 3, text: "例文。")
            let verification = AmbientResultVerification(expected: "例文。", range: NSRange(location: 0, length: 3),
                selectionAtWrite: NSRange(location: 7, length: 0))
            XCTAssertTrue(verification.isCurrent(runtime: runtime, input: input))
            if scenario == 0 { _ = runtime.state.receive(.text("a")) }
            if scenario == 1 { _ = runtime.state.receive(.convert, canReplacePrevious: true) }
            if scenario == 2 { runtime.replacement.anchor = ReplacementAnchor(end: 4, text: "例文。") }
            if scenario == 3 { input.selection = NSRange(location: 1, length: 0) }
            if scenario == 4 { input.reportedCommittedMarkedRange = NSRange(location: 0, length: 3) }
            XCTAssertFalse(verification.isCurrent(runtime: runtime, input: input), "scenario \(scenario)")
            XCTAssertTrue(input.writes.isEmpty)
        }
    }

    func testDeferredVerificationIsNotUsedForAnUnverifiedSource() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        input.canReadMarked = false
        input.committedReadOverride = "different"
        _ = applier(runtime).apply(runtime.state.receive(.text("sample.")), to: input)
        var deferred = false
        XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(
            ConversionResult(candidates: ["例文。"]), to: input, allowUnreadableComposition: true,
            onDeferredVerification: { _ in deferred = true }))
        XCTAssertFalse(deferred)
        XCTAssertEqual(input.text, "sample.")
        XCTAssertEqual(input.writes, ["marked", "insert"])
    }

    func testCommitReportDistinguishesChangedCoordinateScopeWithoutKeepingText() {
        let source = "nihongo desu."
        let input = RecordingInputClient(text: source)
        input.emptyOutOfBoundsReads = true
        let report = AmbientCommitReport(source: source,
            originalRange: NSRange(location: 22, length: 13), input: input)
        XCTAssertEqual(report.selection, NSRange(location: 13, length: 0))
        XCTAssertEqual(report.originalReadLength, 0)
        XCTAssertEqual(report.originalComparison, .empty)
        XCTAssertEqual(report.caretRange, NSRange(location: 0, length: 13))
        XCTAssertEqual(report.caretReadLength, 13)
        XCTAssertEqual(report.caretComparison, .equal)
        XCTAssertFalse(report.originalComparison.rawValue.contains(source))
        XCTAssertFalse(report.caretComparison.rawValue.contains(source))
    }

    func testCommitReportClassifiesFormattingWithoutRelaxingComparisonOrAddingWrites() {
        for (text, expected) in [("Abc", AmbientCommitReport.Comparison.caseOnly),
                                 ("xyz", .different), ("abcd", .differentLength)] {
            let input = RecordingInputClient(text: text)
            input.committedReadOverride = text
            let report = AmbientCommitReport(source: "abc", originalRange: NSRange(location: 0, length: 3), input: input)
            XCTAssertEqual(report.originalComparison, expected)
            XCTAssertTrue(input.writes.isEmpty)
        }
    }

    func testSourceMismatchReportsLengthsWithoutIgnoringDifferentOrEmptyText() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
        input.text = "xyz"
        var report: AmbientSourceReadReport?
        let result = AmbientInputSnapshot.capture(source: "abc", input: input,
            allowUnreadableComposition: true, onSourceRead: { ranges, count in
                report = AmbientSourceReadReport(requestedLength: ranges.marked.length, returnedLength: count)
            })
        if case .failure(let reason) = result { XCTAssertEqual(reason, .sourceMismatch) }
        else { XCTFail("Known different text must not be ignored") }
        XCTAssertEqual(report, AmbientSourceReadReport(requestedLength: 3, returnedLength: 3))
        XCTAssertEqual(report?.returnedDescription, "3")
        input.markedReadOverride = ""
        let empty = AmbientInputSnapshot.capture(source: "abc", input: input,
            allowUnreadableComposition: true, onSourceRead: { ranges, count in
                report = AmbientSourceReadReport(requestedLength: ranges.marked.length, returnedLength: count)
            })
        if case .failure(let reason) = empty { XCTAssertEqual(reason, .sourceMismatch) }
        else { XCTFail("Empty response must remain rejected until its meaning is verified") }
        XCTAssertEqual(report?.returnedLength, 0)
        input.canReadMarked = false
        _ = AmbientInputSnapshot.capture(source: "abc", input: input, onSourceRead: { ranges, count in
            report = AmbientSourceReadReport(requestedLength: ranges.marked.length, returnedLength: count)
        })
        XCTAssertEqual(report?.returnedDescription, "取得不可")
    }

    func testDeliveryDiagnosticsDistinguishCommitFailureAndNeverOverwriteFirstReason() {
        for scenario in 0..<3 {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: String(repeating: "x", count: 22))
            input.reportsRelativeMarkedCaret = true
            input.keepsRelativeCaretAfterCommit = true
            input.canReadMarked = false
            if scenario == 0 { input.canRead = false }
            if scenario == 1 { input.committedReadOverride = "different" }
            if scenario == 2 { input.onInsert = { runtime.cancelForTargetChange(rescueMarked: false) } }
            _ = applier(runtime).apply(runtime.state.receive(.text("kore wa desu.")), to: input)
            var reasons: [AmbientDeliveryFailure] = []
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]),
                to: input, allowUnreadableComposition: true, onFailure: { reasons.append($0) }))
            XCTAssertEqual(reasons, [scenario == 0 ? .committedSourceUnavailable :
                scenario == 1 ? .committedSourceMismatch : .requestChangedDuringCommit])
            XCTAssertEqual(input.writes, ["marked", "insert"])
            XCTAssertEqual(input.text, String(repeating: "x", count: 22) + "kore wa desu.")
        }
    }

    func testRelativeEndCaretMatchesObservedCodexRangesAndStillTracksRawSelection() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: String(repeating: "x", count: 22))
        input.reportsRelativeMarkedCaret = true
        input.canReadMarked = false
        _ = applier(runtime).apply(runtime.state.receive(.text("kore wa desu.")), to: input)
        let snapshot = AmbientInputSnapshot(source: "kore wa desu.", input: input, allowUnreadableComposition: true)
        XCTAssertEqual(snapshot?.marked, NSRange(location: 22, length: 13))
        XCTAssertEqual(snapshot?.selection, NSRange(location: 13, length: 0))
        XCTAssertEqual(snapshot?.reportsRelativeEndCaret, true)
        XCTAssertTrue(snapshot?.matches(input) ?? false)
        input.selection.location -= 1
        XCTAssertFalse(snapshot?.matches(input) ?? true)
        XCTAssertNil(AmbientInputSnapshot(source: "kore wa desu.", input: input, allowUnreadableComposition: true))
    }

    func testRelativeCompositionCommitNormalizesOnlyVerifiedTargetAndKeepsUndoWriteOrder() {
        let source = "kore wa desu."
        let prefix = source + " prefix  " // Same source also occurs earlier: never replace it.
        for relativeAfterCommit in [false, true] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: prefix)
            input.reportsRelativeMarkedCaret = true
            input.keepsRelativeCaretAfterCommit = relativeAfterCommit
            input.canReadMarked = false
            _ = applier(runtime).apply(runtime.state.receive(.text(source)), to: input)
            XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["これは日本語です。"]),
                to: input, allowUnreadableComposition: true))
            XCTAssertEqual(input.text, prefix + "これは日本語です。")
            XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
            XCTAssertEqual(input.insertedValues, [source, "これは日本語です。"])
            XCTAssertEqual(input.beforeInserts.last, prefix + source)
            XCTAssertEqual(runtime.replacement.anchor?.range.location, 22)
        }
    }

    func testAmbiguousInteriorCaretIsNotAssumedToBeRelative() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix ")
        input.reportsRelativeMarkedCaret = true
        _ = applier(runtime).apply(runtime.state.receive(.text("kore wa desu.")), to: input)
        // Relative 13 overlaps the absolute marked range (7,13); do not guess.
        XCTAssertNil(AmbientInputSnapshot(source: "kore wa desu.", input: input))
        input.writes = []
        XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]),
            to: input, allowUnreadableComposition: true))
        XCTAssertTrue(input.writes.isEmpty)
    }

    func testRelativeCaretNeverAllowsReplacementWhenRecordedCommittedRangeCannotBeVerified() {
        for unreadable in [false, true] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: String(repeating: "x", count: 22))
            input.reportsRelativeMarkedCaret = true
            input.keepsRelativeCaretAfterCommit = true
            input.canReadMarked = false
            if unreadable { input.canRead = false } else { input.committedReadOverride = "different" }
            _ = applier(runtime).apply(runtime.state.receive(.text("kore wa desu.")), to: input)
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]),
                to: input, allowUnreadableComposition: true))
            XCTAssertEqual(input.text, String(repeating: "x", count: 22) + "kore wa desu.")
            XCTAssertEqual(input.writes, ["marked", "insert"])
            XCTAssertNil(runtime.state.pending)
        }
    }

    func testSelectionMismatchReportsOnlyTheExactNumericRangesUsedByTheCheck() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix ")
        _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
        var report: AmbientRangeReport?
        func capture() -> Result<AmbientInputSnapshot, AmbientObservationBlock> {
            AmbientInputSnapshot.capture(source: "abc", input: input, allowUnreadableComposition: true,
                onSelectionMismatch: { report = AmbientRangeReport(marked: $0, selection: $1) })
        }
        _ = capture()
        XCTAssertNil(report)
        input.selection = NSRange(location: 7, length: 0)
        if case .failure(let reason) = capture() { XCTAssertEqual(reason, .selectionMismatch) }
        else { XCTFail("Start caret remains ineligible") }
        XCTAssertEqual(report?.marked, NSRange(location: 7, length: 3))
        XCTAssertEqual(report?.selection, NSRange(location: 7, length: 0))
        XCTAssertEqual(report?.markedDescription, "位置 7、長さ 3")
        XCTAssertEqual(report?.selectionDescription, "位置 7、長さ 0")
        XCTAssertEqual(AmbientRangeReport(marked: NSRange(location: NSNotFound, length: 0),
            selection: NSRange(location: -1, length: -1)).markedDescription, "位置 不明、長さ 0")
        XCTAssertFalse(report?.markedDescription.contains("abc") ?? true)
    }

    func testUnreadableCompositionRequiresExplicitFallbackAndKeepsRangeAndSourceChecks() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "prefix ")
        input.canReadMarked = false
        input.reportsMarkedAsSelection = true
        _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
        XCTAssertNil(AmbientInputSnapshot(source: "abc", input: input))
        let snapshot = AmbientInputSnapshot(source: "abc", input: input, allowUnreadableComposition: true)
        XCTAssertEqual(snapshot?.requiresCommittedValidation, true)
        XCTAssertTrue(snapshot?.matches(input) ?? false)
        input.canReadMarked = true
        input.text = "prefix xyz"
        XCTAssertFalse(snapshot?.matches(input) ?? true)
        XCTAssertNil(AmbientInputSnapshot(source: "abc", input: input, allowUnreadableComposition: true))
        input.canReadMarked = false
        input.reportsMarkedAsSelection = false
        input.selection = NSRange(location: 8, length: 0)
        XCTAssertFalse(snapshot?.matches(input) ?? true)
        XCTAssertNil(AmbientInputSnapshot(source: "abc", input: input, allowUnreadableComposition: true))
    }

    func testUnreadableCompositionUsesExactlySameOriginalThenReplacementWritesForUndo() {
        for unreadable in [false, true] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: "prefix ")
            input.canReadMarked = !unreadable
            input.reportsMarkedAsSelection = true
            _ = applier(runtime).apply(runtime.state.receive(.text("nihongo.")), to: input)
            XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["日本語。"]),
                to: input, allowUnreadableComposition: unreadable))
            XCTAssertEqual(input.text, "prefix 日本語。")
            XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
            XCTAssertEqual(input.insertedValues, ["nihongo.", "日本語。"])
            // This verifies operation ordering, not native Undo grouping in each app.
            XCTAssertEqual(input.beforeInserts.last, "prefix nihongo.")
            XCTAssertEqual(runtime.state.previous?.source, "nihongo.")
            XCTAssertTrue(runtime.replacement.validatesAnchor(in: ReplacementInput(input), expected: "日本語。"))
        }
    }

    func testFallbackLeavesCommittedOriginalWhenCommittedSourceIsUnreadableOrDifferent() {
        for unreadable in [false, true] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient(text: "prefix ")
            input.canReadMarked = false
            if unreadable { input.canRead = false }
            else { input.committedReadOverride = "different" }
            _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["結果"]),
                to: input, allowUnreadableComposition: true))
            XCTAssertEqual(input.text, "prefix abc")
            XCTAssertEqual(input.writes, ["marked", "insert"])
            XCTAssertEqual(input.insertedValues, ["abc"])
            XCTAssertNil(runtime.state.pending)
            XCTAssertTrue(runtime.state.marked.isEmpty)
            XCTAssertNil(runtime.state.previous)
        }
    }

    func testFallbackStillRejectsKnownMismatchInvalidSelectionEmptyResultAndPendingManualRequest() {
        for scenario in 0..<4 {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient()
            _ = applier(runtime).apply(runtime.state.receive(.text("abc")), to: input)
            if scenario == 0 { input.text = "xyz" }
            if scenario == 1 { input.selection = NSRange(location: 1, length: 0); input.canReadMarked = false }
            if scenario == 3 { _ = runtime.state.receive(.convert) }
            input.writes = []
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(
                ConversionResult(candidates: scenario == 2 ? [] : ["結果"]), to: input,
                allowUnreadableComposition: true))
            XCTAssertTrue(input.writes.isEmpty)
        }
    }
    func testUnreadableCompositionCanChangeCoordinateScopeAfterCommitWithoutExtraWrites() {
        for staleRead in [nil, "older input."] as [String?] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient()
            let source = "sample text."
            input.canReadMarked = false
            input.reportsRelativeMarkedCaret = true
            input.reportedMarkedOffset = 22
            input.staleRangeRead = staleRead
            _ = applier(runtime).apply(runtime.state.receive(.text(source)), to: input)
            XCTAssertEqual(input.markedRange(), NSRange(location: 22, length: source.utf16.count))
            XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(
                ConversionResult(candidates: ["例文。"]), to: input, allowUnreadableComposition: true))
            XCTAssertEqual(input.text, "例文。")
            XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
            XCTAssertEqual(input.insertedValues, [source, "例文。"])
            XCTAssertEqual(input.beforeInserts.last, source)
            XCTAssertEqual(runtime.replacement.anchor?.range, NSRange(location: 0, length: 3))
        }
    }

    func testChangedCoordinateScopeStillRequiresExactCommittedSource() {
        for actual in ["Sample text.", "sample text", ""] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient()
            input.canReadMarked = false
            input.reportsRelativeMarkedCaret = true
            input.reportedMarkedOffset = 22
            input.staleRangeRead = "older input."
            input.committedReadOverride = actual
            _ = applier(runtime).apply(runtime.state.receive(.text("sample text.")), to: input)
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(
                ConversionResult(candidates: ["例文。"]), to: input, allowUnreadableComposition: true))
            XCTAssertEqual(input.text, "sample text.")
            XCTAssertEqual(input.writes, ["marked", "insert"])
        }
    }

    func testChangedCoordinateScopeRejectsUnfinishedCompositionAndNonCaretSelection() {
        for unfinished in [false, true] {
            let runtime = isolatedRuntime()
            let input = RecordingInputClient()
            input.canReadMarked = false
            input.reportsRelativeMarkedCaret = true
            input.reportedMarkedOffset = 22
            input.staleRangeRead = "older input."
            _ = applier(runtime).apply(runtime.state.receive(.text("sample text.")), to: input)
            input.onInsert = {
                if unfinished { input.reportedCommittedMarkedRange = NSRange(location: 22, length: 12) }
                else { input.selection = NSRange(location: 12, length: 1) }
            }
            XCTAssertFalse(AmbientResultApplier(runtime: runtime).apply(
                ConversionResult(candidates: ["例文。"]), to: input, allowUnreadableComposition: true))
            XCTAssertEqual(input.text, "sample text.")
            XCTAssertEqual(input.writes, ["marked", "insert"])
        }
    }

    func testLongManualAndAmbientDeliveryPreserveOriginalCommitAndSurroundingText() {
        for source in [99, 100, 101, 200].map({ String(repeating: "a", count: $0) }) + [String(repeating: "😀", count: 99)] {
            for ambient in [false, true] {
                let runtime = isolatedRuntime()
                let input = RecordingInputClient(text: "prefix ")
                let effects = applier(runtime)
                _ = effects.apply(runtime.state.receive(.text(source)), to: input)
                if ambient {
                    XCTAssertTrue(AmbientResultApplier(runtime: runtime).apply(ConversionResult(candidates: ["長文の結果"]), to: input))
                } else {
                    _ = effects.apply(runtime.state.receive(.convert), to: input)
                    let request = runtime.state.pending!
                    XCTAssertNil(runtime.replacement.resolvePendingTarget(request, in: ReplacementInput(input)))
                    runtime.originalCommitted = false
                    _ = runtime.state.completeFirst(id: request.id, result: "長文の結果")
                    _ = effects.apply([.replacePrevious(from: source, to: "長文の結果")], to: input)
                }
                XCTAssertEqual(input.text, "prefix 長文の結果")
                XCTAssertEqual(input.writes, ["marked", "insert", "insert"])
                XCTAssertEqual(input.beforeInserts.last, "prefix " + source)
                XCTAssertEqual(runtime.state.previous?.source, source)
                XCTAssertNil(runtime.feedback.notice)
            }
        }
    }

    func testRejectedLongReplacementReportsCauseWithoutWritingOrClaimingSuccess() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let source = String(repeating: "a", count: 101)
        let effects = applier(runtime)
        _ = effects.apply(runtime.state.receive(.text(source)), to: input)
        _ = effects.apply(runtime.state.receive(.convert), to: input)
        let id = runtime.state.pending!.id
        _ = runtime.state.receive(.text("queued"))
        var delivery = runtime.state.completeFirst(id: id, result: "結果")
        delivery[0] = .replacePrevious(from: source, to: "結果")
        runtime.originalCommitted = false
        input.canRead = false
        let writes = input.writes
        _ = effects.apply(delivery, to: input)
        XCTAssertEqual(input.text, source)
        XCTAssertEqual(input.writes, writes)
        XCTAssertEqual(runtime.rescuedText, "queued")
        XCTAssertNil(runtime.state.previous)
        XCTAssertEqual(runtime.feedback.notice?.stage, ConversionDeliveryStage.replacement.rawValue)
        XCTAssertEqual(runtime.feedback.notice?.message, ReplacementValidationFailure.sourceUnavailable.message)
        XCTAssertTrue(runtime.feedback.notice?.details?.contains("101文字") ?? false)
    }

    func testMovedSelectionDuringReplacementIsSilentAndCannotWrite() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "abc")
        runtime.replacement.anchor = ReplacementAnchor(end: 3, text: "abc")
        input.selection = NSRange(location: 1, length: 0)
        _ = applier(runtime).apply([.replacePrevious(from: "abc", to: "結果")], to: input)
        XCTAssertTrue(input.writes.isEmpty)
        XCTAssertNil(runtime.feedback.notice)
        XCTAssertEqual(input.text, "abc")
    }

    func testSnapshotSeparatesReadFailureFromActualTargetChange() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let source = String(repeating: "a", count: 101)
        _ = applier(runtime).apply(runtime.state.receive(.text(source)), to: input)
        let snapshot = AmbientInputSnapshot(source: source, input: input)!
        input.canRead = false
        XCTAssertEqual(snapshot.validationFailure(in: input), .sourceUnavailable)
        input.canRead = true
        input.markedReadOverride = String(repeating: "a", count: 100)
        var readLength: Int?
        XCTAssertEqual(snapshot.validationFailure(in: input, onSourceRead: { readLength = $0 }), .sourceMismatch)
        XCTAssertEqual(readLength, 100)
        input.selection = NSRange(location: 0, length: 0)
        XCTAssertEqual(snapshot.validationFailure(in: input), .targetChanged)
    }

    func testDeliveryErrorIsReportedAfterCleanupSoItsCaretCueIsNotDismissed() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "abc")
        runtime.replacement.anchor = ReplacementAnchor(end: 3, text: "abc")
        input.canRead = false
        var reports = 0
        runtime.feedback.onNotice = {
            reports += 1
            XCTAssertNil(runtime.replacement.anchor)
            XCTAssertNil(runtime.state.previous)
        }
        _ = applier(runtime).apply([.replacePrevious(from: "abc", to: "結果")], to: input)
        XCTAssertEqual(reports, 1)
        XCTAssertTrue(input.writes.isEmpty)
    }

    func testPrematureClientCompositionEndDoesNotDuplicateCommitOnStartFirst() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let applier = applier(runtime) { _, _ in }
        _ = applier.apply(runtime.state.receive(.text("nihongo")), to: input)
        XCTAssertEqual(input.text, "nihongo")
        XCTAssertEqual(runtime.lastMarkedStart, 0)
        // Simulate client ending its composition early while "nihongo" is committed at 0.
        input.insertText("nihongo", replacementRange: NSRange(location: 0, length: 7))
        XCTAssertEqual(input.text, "nihongo")
        XCTAssertEqual(input.markedRange().location, NSNotFound)
        XCTAssertEqual(input.selectedRange(), NSRange(location: 7, length: 0))

        // startFirst should recognize "nihongo" is already committed and anchor at 7
        _ = applier.apply(runtime.state.receive(.convert), to: input)
        XCTAssertEqual(input.text, "nihongo")
        XCTAssertEqual(runtime.replacement.anchor?.range, NSRange(location: 0, length: 7))

        // When conversion completes, replacement replaces "nihongo" with "日本語"
        _ = applier.apply([.replacePrevious(from: "nihongo", to: "日本語")], to: input)
        XCTAssertEqual(input.text, "日本語")
    }

    func testReentrantCommitDuringStartFirstDoesNotDoubleCommit() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let applier = applier(runtime) { _, _ in }
        _ = applier.apply(runtime.state.receive(.text("nihongo")), to: input)
        XCTAssertEqual(input.text, "nihongo")
        input.onInsert = {
            XCTAssertTrue(runtime.originalCommitted)
        }
        _ = applier.apply(runtime.state.receive(.convert), to: input)
        XCTAssertEqual(input.text, "nihongo")
    }

    func testClientDuplicatingOnCommitIsDetectedAndDoesNotAnchorOrReplaceSecondCopy() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient()
        let applier = applier(runtime) { _, _ in }
        _ = applier.apply(runtime.state.receive(.text("nihongo")), to: input)
        input.onInsert = {
            input.text = "nihongonihongo"
            input.selection = NSRange(location: 14, length: 0)
        }
        _ = applier.apply(runtime.state.receive(.convert), to: input)
        XCTAssertNil(runtime.replacement.anchor)

        var rejected = false
        var testApplier = applier
        testApplier.onReplacementRejected = { _ in rejected = true }
        _ = testApplier.apply([.replacePrevious(from: "nihongo", to: "日本語")], to: input)
        XCTAssertTrue(rejected)
        XCTAssertEqual(input.text, "nihongonihongo")
    }

    func testReplacePreviousRefusesToWriteWhileClientIsMarked() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "nihongo")
        runtime.replacement.anchor = ReplacementAnchor(end: 7, text: "nihongo")
        input.setMarkedText("nihongo", selectionRange: NSRange(location: 7, length: 0),
                            replacementRange: NSRange(location: 0, length: 7))
        XCTAssertNotEqual(input.markedRange().location, NSNotFound)

        var rejected = false
        var testApplier = applier(runtime)
        testApplier.onReplacementRejected = { _ in rejected = true }
        _ = testApplier.apply([.replacePrevious(from: "nihongo", to: "日本語")], to: input)
        XCTAssertTrue(rejected)
        XCTAssertEqual(input.text, "nihongo")
    }

    func testResultVerificationDetectsAppendedResultInsteadOfSilentlyCancelling() {
        let runtime = isolatedRuntime()
        let input = RecordingInputClient(text: "nihongo日本語")
        // "nihongo" (7) was supposed to be replaced at (0, 7) by "日本語" (3).
        // If client appended "日本語" instead of replacing, caret is at 0 + 7 + 3 = 10.
        input.selection = NSRange(location: 10, length: 0)
        _ = runtime.state.receive(.text("nihongo"))
        _ = runtime.state.receive(.convert)
        let id = runtime.state.pending!.id
        _ = runtime.state.completeFirst(id: id, result: "日本語")
        runtime.replacement.anchor = ReplacementAnchor(end: 3, text: "日本語")
        let verification = AmbientResultVerification(expected: "日本語", range: NSRange(location: 0, length: 3),
            selectionAtWrite: NSRange(location: 7, length: 0), sourceUTF16: 7)
        // isCurrent MUST remain true so verification is not silently cancelled!
        XCTAssertTrue(verification.isCurrent(runtime: runtime, input: input))
        // readback reads range (0, 3) which is "nih" -> reports mismatch!
        XCTAssertEqual(verification.readback(input), .mismatch)
    }

    private func applier(_ runtime: InputRuntime,
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
    var canReadMarked = true
    var committedReadOverride: String?
    var markedReadOverride: String?
    var emptyOutOfBoundsReads = false
    var reportsMarkedAsSelection = false
    var reportsRelativeMarkedCaret = false
    var keepsRelativeCaretAfterCommit = false
    var reportedMarkedOffset: Int?
    var staleRangeRead: String?
    var reportedCommittedMarkedRange: NSRange?
    var writes: [String] = []
    var insertedValues: [String] = []
    var beforeInserts: [String] = []
    var onInsert: (() -> Void)?
    var onRead: (() -> Void)?
    let rect = NSRect(x: 10, y: 20, width: 100, height: 20)
    init(text: String = "") { self.text = text; selection = NSRange(location: text.utf16.count, length: 0) }
    func selectedRange() -> NSRange {
        if reportsMarkedAsSelection, marked.location != NSNotFound { return marked }
        if reportsRelativeMarkedCaret, marked.location != NSNotFound {
            return NSRange(location: selection.location - marked.location, length: selection.length)
        }
        return selection
    }
    func markedRange() -> NSRange {
        if marked.location == NSNotFound, let reportedCommittedMarkedRange { return reportedCommittedMarkedRange }
        if marked.location != NSNotFound, let reportedMarkedOffset {
            return NSRange(location: reportedMarkedOffset, length: marked.length)
        }
        return marked
    }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        onRead?()
        let value = text as NSString
        guard canRead else { return nil }
        if marked.location == NSNotFound, range.location == reportedMarkedOffset {
            return staleRangeRead.map { NSAttributedString(string: $0) }
        }
        guard range.location <= value.length, range.length <= value.length - range.location else {
            return emptyOutOfBoundsReads ? NSAttributedString(string: "") : nil
        }
        if marked.location != NSNotFound, !canReadMarked { return nil }
        if marked.location != NSNotFound, let markedReadOverride { return NSAttributedString(string: markedReadOverride) }
        if marked.location == NSNotFound, let committedReadOverride { return NSAttributedString(string: committedReadOverride) }
        return NSAttributedString(string: value.substring(with: range))
    }
    func insertText(_ text: Any, replacementRange: NSRange) {
        let value = string(text)
        let relativeCaret = keepsRelativeCaretAfterCommit && marked.location != NSNotFound ? marked.length : nil
        insertedValues.append(value)
        beforeInserts.append(self.text)
        let range = target(replacementRange)
        self.text = (self.text as NSString).replacingCharacters(in: range, with: value)
        marked = NSRange(location: NSNotFound, length: 0)
        if updateCaretAfterWrite { selection = NSRange(location: relativeCaret ?? (range.location + value.utf16.count), length: 0) }
        writes.append("insert")
        onInsert?()
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
    /// Simulates a client that cancels composition instead of committing on movement.
    func passLeftArrowDiscardingComposition() {
        if marked.location != NSNotFound {
            text = (text as NSString).replacingCharacters(in: marked, with: "")
            selection = NSRange(location: marked.location, length: 0)
            marked = NSRange(location: NSNotFound, length: 0)
        }
        selection = NSRange(location: max(0, selection.location - 1), length: 0)
    }
    private func target(_ range: NSRange) -> NSRange {
        range.location != NSNotFound ? range : (marked.location != NSNotFound ? marked : selection)
    }
    private func string(_ value: Any) -> String { (value as? NSAttributedString)?.string ?? (value as! String) }
}

private actor NavigationScoreGate {
    private var continuation: CheckedContinuation<Double, Never>?
    private(set) var started = false
    func score() async -> Double {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func finish() { continuation?.resume(returning: 1); continuation = nil }
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
