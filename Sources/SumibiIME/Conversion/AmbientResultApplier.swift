import Foundation
import SumibiCore

enum AmbientDeliveryFailure: String {
    case targetChangedBeforeCommit = "原文確定前に入力状態または未確定範囲が変わりました。"
    case emptyCandidate = "適用する変換候補がありません。"
    case requestChangedDuringCommit = "原文確定中に入力セッションの状態が変わりました。"
    case committedSourceUnavailable = "原文確定後の文字列を読み取れません。原文は残しました。"
    case committedSourceMismatch = "原文確定後の文字列が原文と一致しません。結果は適用していません。"
    case committedTargetMismatch = "原文確定後の範囲または選択位置を確認できません。原文は残しました。"
    case resultUnavailable = "置換後の変換結果を確認できません。"
    case replacementRejected = "置換直前の原文照合に失敗し、変換結果を書き込んでいません。原文は残しました。"

    var isCancellation: Bool {
        self == .targetChangedBeforeCommit || self == .requestChangedDuringCommit
    }
}

/// A prepared result is delivered synchronously, with the same source commit and tracked
/// replacement as manual conversion. Optional read waits never send another request.
struct AmbientResultApplier {
    let runtime: InputRuntime

    func apply(_ result: ConversionResult, to input: any InputClient,
               allowUnreadableComposition: Bool = false,
               onFailure: ((AmbientDeliveryFailure) -> Void)? = nil,
               onCommitReport: ((AmbientCommitReport) -> Void)? = nil,
               onCommitTextReport: ((AmbientCommitTextReport) -> Void)? = nil,
               onResultTextReport: ((AmbientResultTextReport) -> Void)? = nil,
               onDeferredVerification: ((AmbientResultVerification) -> Void)? = nil,
               onDeferredSource: ((AmbientSourceVerification) -> Void)? = nil) -> Bool {
        var recordedFailure = false
        var replacementWritten = false
        var sourceDeferred = false
        func fail(_ reason: AmbientDeliveryFailure) -> Bool {
            if !recordedFailure { recordedFailure = true; onFailure?(reason) }
            return false
        }
        let source = runtime.state.marked
        guard runtime.state.pending == nil, !runtime.candidates.shouldBeVisible,
              let snapshot = AmbientInputSnapshot(source: source, input: input,
                                   allowUnreadableComposition: allowUnreadableComposition) else {
            return fail(.targetChangedBeforeCommit)
        }
        guard let first = result.candidates.first, !first.isEmpty else { return fail(.emptyCandidate) }
        let effects = runtime.state.receive(.convert)
        guard case .startFirst? = effects.first else { return fail(.targetChangedBeforeCommit) }
        func deferSource(_ request: PendingRequest) -> Bool {
            guard let onDeferredSource,
                  let verification = AmbientSourceVerification(snapshot: snapshot, request: request,
                      candidate: first, runtime: runtime, input: input) else { return false }
            runtime.awaitingAmbientSourceID = request.id
            sourceDeferred = true
            onDeferredSource(verification)
            return true
        }
        let applier = InputEffectApplier(runtime: runtime, startConversion: { id, _ in
            // The original commit is the existing Undo-preserving operation. Even when
            // marked text cannot be read, committed source must be readable and identical
            // before any result is written. Failure leaves the committed original intact.
            guard let request = runtime.state.pending, request.id == id else {
                _ = fail(.requestChangedDuringCommit)
                runtime.cancelForTargetChange(rescueMarked: false)
                return
            }
            let committedInput: any InputClient
            if onCommitReport != nil || onCommitTextReport != nil {
                let report = AmbientCommitReport(source: source, originalRange: snapshot.marked,
                    input: input, captureText: onCommitTextReport)
                onCommitReport?(report)
            }
            let postMarked = input.markedRange()
            if postMarked.location != NSNotFound, postMarked.length > 0 {
                if deferSource(request) { return }
                _ = fail(.committedTargetMismatch)
                runtime.cancelForTargetChange(rescueMarked: false)
                return
            }
            if snapshot.reportsRelativeEndCaret, input.selectedRange() == snapshot.selection {
                // A still-relative post-commit caret must never anchor at document offset
                // `source.count`. Read the exact recorded composition range, not a search
                // window; duplicated source in an earlier prefix is not a valid target.
                let committed = input.attributedSubstring(from: snapshot.marked)?.string
                if committed == source {
                    runtime.replacement.anchor = ReplacementAnchor(
                        end: snapshot.marked.location + snapshot.marked.length, text: source)
                    committedInput = AmbientCommittedInput(input: input, relativeCaret: snapshot.selection,
                        absoluteEnd: snapshot.marked.location + snapshot.marked.length)
                    runtime.replacement.pendingTarget = PendingTarget(requestID: id,
                        selection: committedInput.selectedRange(), expectedText: source, kind: request.kind)
                } else if validatesChangedCoordinateScope(snapshot, source: source, input: input) {
                    // Some clients change coordinate namespaces when composition ends.
                    // Use only the manual path's freshly recorded, exact post-commit target.
                    // Never search for source or prefer a duplicate over a verified old range.
                    committedInput = input
                } else {
                    if committed == nil, deferSource(request) { return }
                    _ = fail(committed == nil ? .committedSourceUnavailable : .committedSourceMismatch)
                    runtime.cancelForTargetChange(rescueMarked: false)
                    return
                }
            } else { committedInput = input }
            guard runtime.replacement.validatesPendingTarget(request, in: ReplacementInput(committedInput)) else {
                if let committed = input.attributedSubstring(from: snapshot.marked)?.string {
                    _ = fail(committed == source ? .committedTargetMismatch : .committedSourceMismatch)
                } else {
                    if deferSource(request) { return }
                    _ = fail(.committedSourceUnavailable)
                }
                runtime.cancelForTargetChange(rescueMarked: false)
                return
            }
            runtime.replacement.pendingTarget = nil
            runtime.originalCommitted = false
            runtime.candidates.dictionaryCandidates = []
            var delivery = runtime.state.completeFirst(id: id, result: first)
            if case .commit(let text)? = delivery.first {
                delivery[0] = .replacePrevious(from: source, to: text)
            }
            let deliveryApplier = InputEffectApplier(runtime: runtime,
                startConversion: { _, _ in }, pokeClient: { _ in }, selectCandidate: { _ in },
                onReplacementWritten: { _, _ in replacementWritten = true },
                onReplacementRejected: { reason in
                    _ = fail(reason.isCancellation ? .targetChangedBeforeCommit : .replacementRejected)
                })
            _ = deliveryApplier.apply(delivery, to: committedInput)
        }, pokeClient: { _ in }, selectCandidate: { _ in })
        _ = applier.apply(effects, to: input)
        if sourceDeferred { return false }
        let stateMatches = runtime.state.previous?.result == first
        let range = runtime.replacement.anchor?.range
        let actual = stateMatches ? range.flatMap { input.attributedSubstring(from: $0)?.string } : nil
        if let onResultTextReport {
            onResultTextReport(.capture(expected: first, range: range, actual: actual,
                                       stateMatches: stateMatches, input: input))
        }
        guard stateMatches, let range, Self.verifiesResult(expected: first, range: range, in: input) else {
            if replacementWritten, !recordedFailure, stateMatches, let anchor = runtime.replacement.anchor,
               anchor.text == first, anchor.span == first.utf16.count,
               let onDeferredVerification {
                // The replacement effect has updated its anchor after insertText.
                // Do not write again or clear successful conversion state while the
                // client is still exposing its pre-replacement text.
                onDeferredVerification(AmbientResultVerification(expected: first, range: anchor.range,
                    selectionAtWrite: input.selectedRange(), sourceUTF16: source.utf16.count))
                return false
            }
            runtime.cancelForTargetChange(rescueMarked: false)
            return fail(.resultUnavailable)
        }
        return true
    }

    /// Resume only an owned committed-source wait. No original commit or API call here.
    func resumeSource(_ verification: AmbientSourceVerification, to input: any InputClient,
                      deadline: TimeInterval? = nil,
                      mayApply: () -> Bool = { true },
                      onCommitReport: ((AmbientCommitReport) -> Void)? = nil,
                      onCommitTextReport: ((AmbientCommitTextReport) -> Void)? = nil,
                      onResultTextReport: ((AmbientResultTextReport) -> Void)? = nil,
                      onDeferredVerification: ((AmbientResultVerification) -> Void)? = nil)
        -> AmbientConversionLifecycle.SourceResolution {
        guard verification.isCurrent(runtime: runtime, input: input) else { return .cancelled }
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return .failed(.committedSourceUnavailable) }
        let snapshot = verification.snapshot
        let source = snapshot.source
        if onCommitReport != nil || onCommitTextReport != nil {
            onCommitReport?(AmbientCommitReport(source: source, originalRange: snapshot.marked,
                input: input, captureText: onCommitTextReport))
        }
        // The client may still expose its just-ended composition. Never write while
        // it is marked, even if a read already returns the original.
        let marked = input.markedRange()
        guard marked.location == NSNotFound || marked.length == 0 else { return .waiting }
        let previousAnchor = runtime.replacement.anchor
        let previousTarget = runtime.replacement.pendingTarget
        func waitForSource() -> AmbientConversionLifecycle.SourceResolution {
            guard runtime.awaitingAmbientSourceID == verification.request.id,
                  runtime.state.pending == verification.request, runtime.state.queuedKeys.isEmpty else { return .cancelled }
            // A read may become unavailable again after relative-caret normalization.
            // Retry against the same frozen coordinates, not partly updated tracking.
            runtime.replacement.anchor = previousAnchor
            runtime.replacement.pendingTarget = previousTarget
            return .waiting
        }
        let committedInput: any InputClient
        if snapshot.reportsRelativeEndCaret, input.selectedRange() == snapshot.selection {
            let committed = input.attributedSubstring(from: snapshot.marked)?.string
            if committed == source {
                runtime.replacement.anchor = ReplacementAnchor(
                    end: snapshot.marked.location + snapshot.marked.length, text: source)
                committedInput = AmbientCommittedInput(input: input, relativeCaret: snapshot.selection,
                    absoluteEnd: snapshot.marked.location + snapshot.marked.length)
                runtime.replacement.pendingTarget = PendingTarget(requestID: verification.request.id,
                    selection: committedInput.selectedRange(), expectedText: source, kind: .first)
            } else if validatesChangedCoordinateScope(snapshot, source: source, input: input) {
                committedInput = input
            } else {
                return committed == nil ? waitForSource() : .failed(.committedSourceMismatch)
            }
        } else { committedInput = input }
        guard runtime.replacement.validatesPendingTarget(verification.request, in: ReplacementInput(committedInput)) else {
            // Never retry different/partial text as though it were the original.
            guard let committed = input.attributedSubstring(from: snapshot.marked)?.string else { return waitForSource() }
            return .failed(committed == source ? .committedTargetMismatch : .committedSourceMismatch)
        }
        // A slow synchronous client read must not cause a write after the deadline.
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return .failed(.committedSourceUnavailable) }
        guard runtime.awaitingAmbientSourceID == verification.request.id,
              runtime.state.pending == verification.request, runtime.state.queuedKeys.isEmpty,
              runtime.state.marked == source, runtime.originalCommitted,
              !runtime.candidates.shouldBeVisible, mayApply() else { return .cancelled }
        runtime.awaitingAmbientSourceID = nil
        runtime.replacement.pendingTarget = nil
        runtime.originalCommitted = false
        runtime.candidates.dictionaryCandidates = []
        let first = verification.candidate
        var delivery = runtime.state.completeFirst(id: verification.request.id, result: first)
        if case .commit(let text)? = delivery.first { delivery[0] = .replacePrevious(from: source, to: text) }
        var written = false
        var rejected: ReplacementValidationFailure?
        let applier = InputEffectApplier(runtime: runtime,
            startConversion: { _, _ in }, pokeClient: { _ in }, selectCandidate: { _ in },
            onReplacementWritten: { _, _ in written = true },
            onReplacementRejected: { rejected = $0 })
        _ = applier.apply(delivery, to: committedInput)
        if let rejected {
            return rejected.isCancellation ? .cancelled : .failed(.replacementRejected)
        }
        let stateMatches = runtime.state.previous?.result == first
        let range = runtime.replacement.anchor?.range
        let actual = stateMatches ? range.flatMap { input.attributedSubstring(from: $0)?.string } : nil
        onResultTextReport?(.capture(expected: first, range: range, actual: actual,
            stateMatches: stateMatches, input: input))
        if stateMatches, let range, Self.verifiesResult(expected: first, range: range, in: input) { return .applied }
        if written, stateMatches, let range, let onDeferredVerification {
            onDeferredVerification(AmbientResultVerification(expected: first, range: range,
                selectionAtWrite: input.selectedRange(), sourceUTF16: source.utf16.count))
            return .verifyingResult
        }
        runtime.cancelForTargetChange(rescueMarked: false)
        return .failed(.resultUnavailable)
    }

    private func validatesChangedCoordinateScope(_ snapshot: AmbientInputSnapshot,
                                                source: String, input: any InputClient) -> Bool {
        let selection = input.selectedRange()
        let marked = input.markedRange()
        guard snapshot.requiresCommittedValidation, runtime.originalCommitted,
              marked.location == NSNotFound || marked.length == 0,
              selection.location != NSNotFound, selection.length == 0,
              let anchor = runtime.replacement.anchor,
              anchor.text == source, anchor.span == source.utf16.count,
              anchor.end == selection.location, anchor.end >= anchor.span,
              input.attributedSubstring(from: anchor.range)?.string == source else { return false }
        return true
    }

    static func verifiesResult(expected: String, range: NSRange, in input: any InputClient) -> Bool {
        if let actual = input.attributedSubstring(from: range)?.string {
            return actual == expected
        }
        if range.length > 100, expected.utf16.count == range.length {
            let windowLength = 100
            let windowRange = NSRange(location: range.location + range.length - windowLength, length: windowLength)
            if let windowText = input.attributedSubstring(from: windowRange)?.string,
               windowText.utf16.count == windowLength {
                let expectedSuffix = (expected as NSString).substring(from: expected.utf16.count - windowLength)
                return windowText == expectedSuffix
            }
        }
        return false
    }
}

/// Memory-only state for an already committed original; never re-commit or re-send it.
struct AmbientSourceVerification {
    let snapshot: AmbientInputSnapshot
    let request: PendingRequest
    let candidate: String
    private let selection: NSRange
    private let anchor: ReplacementAnchor
    private let targetSelection: NSRange

    init?(snapshot: AmbientInputSnapshot, request: PendingRequest, candidate: String,
          runtime: InputRuntime, input: any InputClient) {
        let selection = input.selectedRange()
        guard runtime.originalCommitted, runtime.state.pending == request, request.kind == .first,
              runtime.state.marked == snapshot.source, runtime.state.queuedKeys.isEmpty,
              !runtime.candidates.shouldBeVisible,
              selection.location != NSNotFound, selection.length == 0,
              let anchor = runtime.replacement.anchor, anchor.text == snapshot.source,
              anchor.span == snapshot.source.utf16.count, anchor.end >= anchor.span,
              anchor.end == selection.location,
              let target = runtime.replacement.pendingTarget, target.requestID == request.id,
              target.kind == request.kind, target.expectedText == snapshot.source,
              target.selection == selection else { return nil }
        let marked = input.markedRange()
        guard marked.location == NSNotFound || marked.length == 0 || marked == snapshot.marked else { return nil }
        self.snapshot = snapshot; self.request = request; self.candidate = candidate
        self.selection = selection; self.anchor = anchor; targetSelection = target.selection
    }

    func isCurrent(runtime: InputRuntime, input: any InputClient) -> Bool {
        let marked = input.markedRange()
        return runtime.awaitingAmbientSourceID == request.id && runtime.originalCommitted
            && runtime.state.pending == request && runtime.state.marked == snapshot.source
            && runtime.state.queuedKeys.isEmpty && !runtime.candidates.shouldBeVisible
            && input.selectedRange() == selection
            && (marked.location == NSNotFound || marked.length == 0 || marked == snapshot.marked)
            && runtime.replacement.anchor?.end == anchor.end
            && runtime.replacement.anchor?.span == anchor.span
            && runtime.replacement.anchor?.text == anchor.text
            && runtime.replacement.pendingTarget?.requestID == request.id
            && runtime.replacement.pendingTarget?.kind == request.kind
            && runtime.replacement.pendingTarget?.expectedText == snapshot.source
            && runtime.replacement.pendingTarget?.selection == targetSelection
    }

    func cancel(runtime: InputRuntime) {
        guard runtime.awaitingAmbientSourceID == request.id else { return }
        runtime.awaitingAmbientSourceID = nil
        guard runtime.state.pending == request, runtime.originalCommitted else { return }
        // Do not call ambient.stop here: cleanup must not cancel newer observations.
        let effects = runtime.state.cancelForTargetChange(rescueMarked: false)
        for case .rescueText(let text) in effects { runtime.rescuedText += text }
        runtime.originalCommitted = false
        runtime.replacement.anchor = nil; runtime.replacement.pendingTarget = nil
        runtime.selectionRange = nil
    }
}

/// Read-only verification of an already-written result. Never search/re-anchor or write.
struct AmbientResultVerification {
    let expected: String
    let range: NSRange
    let selectionAtWrite: NSRange
    let sourceUTF16: Int

    init(expected: String, range: NSRange, selectionAtWrite: NSRange, sourceUTF16: Int = 0) {
        self.expected = expected
        self.range = range
        self.selectionAtWrite = selectionAtWrite
        self.sourceUTF16 = sourceUTF16
    }

    func isCurrent(runtime: InputRuntime, input: any InputClient) -> Bool {
        let selection = input.selectedRange()
        let marked = input.markedRange()
        let expectedCaret = NSRange(location: range.location + range.length, length: 0)
        let appendedCaret = sourceUTF16 > 0 ? NSRange(location: range.location + sourceUTF16 + range.length, length: 0) : NSRange(location: NSNotFound, length: 0)
        return runtime.state.pending == nil && runtime.state.marked.isEmpty
            && !runtime.candidates.shouldBeVisible && runtime.state.previous?.result == expected
            && runtime.replacement.anchor?.text == expected && runtime.replacement.anchor?.range == range
            && (marked.location == NSNotFound || marked.length == 0)
            && selection.location != NSNotFound
            && (selection == selectionAtWrite || selection == range
                || selection == expectedCaret || selection == appendedCaret)
    }

    func matches(_ input: any InputClient,
                 captureText: ((AmbientResultTextReport) -> Void)? = nil) -> Bool {
        readback(input, captureText: captureText) == .matching
    }

    func readback(_ input: any InputClient,
                  captureText: ((AmbientResultTextReport) -> Void)? = nil) -> ConversionResultReadback {
        let actual = input.attributedSubstring(from: range)?.string
        if let captureText {
            captureText(.capture(expected: expected, range: range, actual: actual,
                                 stateMatches: true, input: input))
        }
        guard let actual else {
            if range.length > 100, expected.utf16.count == range.length {
                let windowLength = 100
                let windowRange = NSRange(location: range.location + range.length - windowLength, length: windowLength)
                if let windowText = input.attributedSubstring(from: windowRange)?.string,
                   windowText.utf16.count == windowLength {
                    let expectedSuffix = (expected as NSString).substring(from: expected.utf16.count - windowLength)
                    if windowText == expectedSuffix { return .matching }
                }
            }
            return .unavailable
        }
        if actual == expected { return .matching }
        if actual.utf16.count != expected.utf16.count { return .lengthMismatch(actual.utf16.count) }
        return .mismatch
    }
}

/// Scoped to one synchronous delivery after exact committed-source verification.
/// Keep legacy manual conversion untouched; do not let its caret-based fallback interpret
/// a known relative offset as a document offset and re-anchor to a duplicate in the prefix.
private struct AmbientCommittedInput: InputClient {
    let input: any InputClient
    let relativeCaret: NSRange
    let absoluteEnd: Int

    func selectedRange() -> NSRange {
        let raw = input.selectedRange()
        return raw == relativeCaret ? NSRange(location: absoluteEnd, length: 0) : raw
    }
    func markedRange() -> NSRange { input.markedRange() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { input.attributedSubstring(from: range) }
    func insertText(_ text: Any, replacementRange: NSRange) { input.insertText(text, replacementRange: replacementRange) }
    func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange) {
        input.setMarkedText(text, selectionRange: selectionRange, replacementRange: replacementRange)
    }
    func lineRect(at index: Int) -> NSRect { input.lineRect(at: index) }
}
