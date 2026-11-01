import AppKit
import InputMethodKit
import SumibiCore


/// Applies state-machine effects to the explicit client, on the main thread.
/// Stateless: runtime owns coordinates/flags; callbacks connect conversion and candidate selection.
struct InputEffectApplier {
    let runtime: InputRuntime
    let startConversion: (Int, ConversionRequest) -> Void
    let pokeClient: (any InputClient) -> Void
    let selectCandidate: (Int) -> Void
    var onReplacementWritten: ((NSRange, String) -> Void)? = nil
    var onReplacementRejected: ((ReplacementValidationFailure) -> Void)? = nil
    private var state: InputSession { runtime.state }

    func apply(_ effects: [SessionEffect], to input: any InputClient) -> Bool {
        var passToClient = false
        for effect in effects {
            switch effect {
            case .marked(let text):
                input.setMarkedText(MarkedTextStyle.attributed(text), selectionRange: NSRange(location: text.utf16.count, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                let markedStart = input.markedRange().location
                if markedStart != NSNotFound {
                    runtime.lastMarkedStart = markedStart
                    let rect = input.lineRect(at: markedStart)
                    if rect.height > 0 { runtime.candidates.lastLineRect = rect }
                } else if text.isEmpty {
                    runtime.lastMarkedStart = nil
                }
            case .commit(let text):
                let alreadyCommitted = state.previous?.result != text && runtime.isMarkedTextAlreadyCommitted(text, in: input)
                let committedStart = runtime.lastMarkedStart
                runtime.lastMarkedStart = nil
                if alreadyCommitted {
                    DiagnosticLog.record(.commitAlreadyPresent, counters: [committedStart ?? -1, text.utf16.count])
                } else {
                    input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                }
                if state.previous?.result == text {
                    let selection = input.selectedRange()
                    if selection.location != NSNotFound, selection.length == 0 {
                        runtime.replacement.anchor = ReplacementAnchor(end: selection.location, text: text)
                    }
                }
            case .passEnter(let deferred):
                if deferred { runtime.deferredControls.append("Enter") } else { passToClient = true }
            case .passBackspace(let deferred):
                if deferred { runtime.deferredControls.append("Backspace") } else { passToClient = true }
            case .passConvert(let deferred):
                if deferred { runtime.deferredControls.append("Control-J") } else { passToClient = true }
            case .passCancel:
                passToClient = true
            case .startFirst(let id, let source):
                // 原文をいったん通常の文字として確定し、応答が来たらその範囲を置換する。
                // 未確定のままだと原文が入力先のUndo履歴に入らず、Undoで原文へ戻せない。
                let preMarked = input.markedRange()
                let trackedStart = runtime.lastMarkedStart
                let alreadyCommitted = runtime.isMarkedTextAlreadyCommitted(source, in: input)
                runtime.lastMarkedStart = nil
                runtime.originalCommitted = true
                if alreadyCommitted {
                    DiagnosticLog.record(.commitAlreadyPresent, counters: [trackedStart ?? -1, source.utf16.count])
                } else {
                    input.insertText(source, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                }
                let caret = input.selectedRange()
                let postMarked = input.markedRange()
                DiagnosticLog.record(.sourceCommitted, counters: [
                    id,
                    preMarked.location == NSNotFound ? -1 : preMarked.location,
                    preMarked.length == NSNotFound ? -1 : preMarked.length,
                    caret.location == NSNotFound ? -1 : caret.location,
                    caret.length == NSNotFound ? -1 : caret.length,
                    postMarked.location == NSNotFound ? -1 : postMarked.location,
                    postMarked.length == NSNotFound ? -1 : postMarked.length
                ])
                let sourceLen = source.utf16.count
                let expectedStart = preMarked.location != NSNotFound ? preMarked.location : trackedStart
                let isDuplicated: Bool = {
                    guard let start = expectedStart, start != NSNotFound, start >= 0, sourceLen > 0,
                          caret.length == 0, caret.location == start + 2 * sourceLen else { return false }
                    let firstRange = NSRange(location: start, length: sourceLen)
                    let secondRange = NSRange(location: start + sourceLen, length: sourceLen)
                    return input.attributedSubstring(from: firstRange)?.string == source
                        && input.attributedSubstring(from: secondRange)?.string == source
                }()
                if isDuplicated {
                    DiagnosticLog.record(.targetMismatch, counters: [expectedStart ?? -1, sourceLen, caret.location])
                    runtime.replacement.anchor = nil
                } else if caret.location != NSNotFound, caret.length == 0 {
                    runtime.replacement.anchor = ReplacementAnchor(end: caret.location, text: source)
                } else if preMarked.location != NSNotFound, preMarked.length == sourceLen, caret == preMarked {
                    runtime.replacement.anchor = ReplacementAnchor(end: preMarked.location + preMarked.length, text: source)
                } else {
                    runtime.replacement.anchor = nil
                }
                runtime.replacement.pendingTarget = PendingTarget(requestID: id, selection: caret, expectedText: source, kind: .first)
                startConversion(id, ConversionRequest(source: source))
            case .startAlternatives(let id, let source, let current):
                runtime.replacement.pendingTarget = PendingTarget(requestID: id, selection: input.selectedRange(),
                                              expectedText: current,
                                              kind: .alternatives)
                // 追加候補の要求では入力先へ何も書かないため、次のセッションを作らせるためにつつく。
                pokeClient(input)
                startConversion(id, ConversionRequest(source: source, mode: .alternatives,
                                                                   currentConversion: current))
            case .startSelection(let id, let source):
                // 選択範囲を同じ文字列で置き換える。表示は変わらないが、この書き込みが
                // 新しい入力セッションを作らせ、応答を届けられるようにする。
                // 置換位置の記録(アンカー)も、未確定文字列からの変換と同じ形になる。
                runtime.lastMarkedStart = nil
                let range = runtime.selectionRange ?? input.selectedRange()
                input.insertText(source, replacementRange: range)
                let caret = input.selectedRange()
                if caret.location != NSNotFound, caret.length == 0 {
                    runtime.replacement.anchor = ReplacementAnchor(end: caret.location, text: source)
                } else {
                    runtime.replacement.anchor = ReplacementAnchor(end: range.location + range.length, text: source)
                }
                runtime.replacement.pendingTarget = PendingTarget(requestID: id, selection: input.selectedRange(),
                                              expectedText: source, kind: .selection)
                startConversion(id, ConversionRequest(source: source))
            case .showCandidates:
                // Store only the weak-controller callback, not this applier (which owns runtime).
                runtime.candidates.show(candidates: state.candidateStrings, in: input, onSelect: selectCandidate)
            case .replacePrevious(let old, let new):
                runtime.lastMarkedStart = nil
                let marked = input.markedRange()
                if marked.location != NSNotFound, marked.length > 0 {
                    let failure = ReplacementValidationFailure.rangeUnavailable
                    runtime.cancelForTargetChange()
                    if let onReplacementRejected {
                        onReplacementRejected(failure)
                    } else if !failure.isCancellation {
                        runtime.feedback.report(.delivery(failure, stage: .replacement,
                            sourceCharacters: old.count, sourceUTF16: old.utf16.count))
                        DiagnosticLog.record(.deliveryUnavailable)
                    }
                    return true
                }
                guard runtime.replacement.validatesAnchor(in: ReplacementInput(input), expected: old), let anchor = runtime.replacement.anchor else {
                    let failure = runtime.replacement.anchorFailure(in: ReplacementInput(input), expected: old)
                    // Stop/rescue first: ambient.stop dismisses old cues. A new error cue
                    // must be emitted after that cleanup, not immediately hidden by it.
                    runtime.cancelForTargetChange()
                    if let onReplacementRejected { onReplacementRejected(failure) }
                    else if !failure.isCancellation {
                        runtime.feedback.report(.delivery(failure, stage: .replacement,
                            sourceCharacters: old.count, sourceUTF16: old.utf16.count))
                        DiagnosticLog.record(.deliveryUnavailable)
                    }
                    // Do not leave a successful `previous` after a skipped replacement.
                    // Rescue queued input; never write subsequent effects to an unverified target.
                    return true
                }
                let range = anchor.range
                input.insertText(new, replacementRange: range)
                let postSelection = input.selectedRange()
                DiagnosticLog.record(.replacementWritten, counters: [
                    range.location,
                    range.length,
                    new.utf16.count,
                    postSelection.location == NSNotFound ? -1 : postSelection.location,
                    postSelection.length == NSNotFound ? -1 : postSelection.length
                ])
                // 置換後の位置は、書き込んだ範囲から決める。Chromeは書き込み直後に
                // 古いカーソル位置を返すことがあり、それを信じると次の置換位置がずれる。
                runtime.replacement.anchor = ReplacementAnchor(end: range.location + new.utf16.count, text: new)
                onReplacementWritten?(range, new)
            case .overLimit:
                DiagnosticLog.record(.overLimit)
                runtime.feedback.report(.failure(.overLimit(count: state.marked.count, limit: 1_000)))
            case .rescueText(let text):
                runtime.rescuedText += text
            }
        }
        return !passToClient
    }
}
