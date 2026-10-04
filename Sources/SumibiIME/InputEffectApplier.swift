import AppKit
import InputMethodKit
import SumibiCore
import os

private let diag = Logger(subsystem: "org.sumibi.inputmethod.Sumibi", category: "diag")

/// Applies state-machine effects to the explicit client, on the main thread.
/// Stateless: runtime owns coordinates/flags; callbacks connect conversion and candidate selection.
struct InputEffectApplier {
    let runtime: InputRuntime
    let startConversion: (Int, ConversionRequest) -> Void
    let pokeClient: (any InputClient) -> Void
    let selectCandidate: (Int) -> Void
    var diagnoseText = false
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
                    let rect = input.lineRect(at: markedStart)
                    if rect.height > 0 { runtime.candidates.lastLineRect = rect }
                }
            case .commit(let text):
                input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
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
                input.insertText(source, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                runtime.originalCommitted = true
                let caret = input.selectedRange()
                if caret.location != NSNotFound, caret.length == 0 {
                    runtime.replacement.anchor = ReplacementAnchor(end: caret.location, text: source)
                } else {
                    runtime.replacement.anchor = nil
                }
                runtime.replacement.pendingTarget = PendingTarget(requestID: id, selection: caret, expectedText: source, kind: .first)
                #if SUMIBI_DEVELOPMENT
                if diagnoseText, caret.location != NSNotFound {
                    let start = max(0, caret.location - source.utf16.count - 40)
                    let around = input.attributedSubstring(from: NSRange(location: start, length: caret.location - start))?.string ?? "(nil)"
                    diag.notice("text: after commit caret=\(caret.location, privacy: .public) \(start, privacy: .public)..<\(caret.location, privacy: .public)=[\(around.replacingOccurrences(of: "\n", with: "\\n"), privacy: .public)]")
                }
                #endif
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
                guard runtime.replacement.validatesAnchor(in: ReplacementInput(input), expected: old), let anchor = runtime.replacement.anchor else { break }
                let range = anchor.range
                input.insertText(new, replacementRange: range)
                // 置換後の位置は、書き込んだ範囲から決める。Chromeは書き込み直後に
                // 古いカーソル位置を返すことがあり、それを信じると次の置換位置がずれる。
                runtime.replacement.anchor = ReplacementAnchor(end: range.location + new.utf16.count, text: new)
            case .overLimit:
                runtime.feedback.report(.failure(.overLimit(count: state.marked.count, limit: 1_000)))
            case .rescueText(let text):
                runtime.rescuedText += text
            }
        }
        return !passToClient
    }
}
