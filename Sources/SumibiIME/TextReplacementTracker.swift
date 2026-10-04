import Foundation
import InputMethodKit
import SumibiCore


/// Read-only boundary: tests can supply a document without starting an IMK server.
/// Closures are evaluated at each read, not snapshotted before a re-anchor.
struct ReplacementInput {
    let selectedRange: () -> NSRange
    private let readSubstring: (NSRange) -> NSAttributedString?

    init(_ input: any IMKTextInput) {
        selectedRange = { input.selectedRange() }
        readSubstring = { input.attributedSubstring(from: $0) }
    }

    init(_ input: any InputClient) {
        selectedRange = { input.selectedRange() }
        readSubstring = { input.attributedSubstring(from: $0) }
    }

    init(selectedRange: @escaping () -> NSRange, substring: @escaping (NSRange) -> String?) {
        self.selectedRange = selectedRange
        readSubstring = { substring($0).map { NSAttributedString(string: $0) } }
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString? { readSubstring(range) }
}

struct ReplacementAnchor {
    var end: Int
    var text: String
    /// 入力先の文書上での長さ(UTF-16)。ターミナルで折り返して表示された原文は、改行と字下げの分だけ`text`より長い。
    var span: Int

    init(end: Int, text: String, span: Int? = nil) {
        self.end = end
        self.text = text
        self.span = span ?? text.utf16.count
    }

    var range: NSRange { NSRange(location: end - span, length: span) }
}

struct PendingTarget {
    let requestID: Int
    let selection: NSRange
    let expectedText: String
    let kind: PendingRequest.Kind
}


/// Owns only replacement coordinates and validation; it never writes to the client.
/// Retained by InputRuntime across short-lived IMK controllers. Main-thread use only.
final class TextReplacementTracker {
    var anchor: ReplacementAnchor?
    var pendingTarget: PendingTarget?

    func validatesPendingTarget(_ request: PendingRequest, in input: ReplacementInput) -> Bool {
        guard let target = pendingTarget,
              target.requestID == request.id,
              target.kind == request.kind else { return false }
        // いずれの要求も、記録した位置(アンカー)に記録した文字列がまだあることを確かめてから置換する。
        let ok = target.selection == input.selectedRange() && validatesAnchor(in: input, expected: target.expectedText)
        DiagnosticLog.record(.targetValidated)
        return ok
    }

    /// ターミナルは書き込んだ文字を少し遅れて反映し、書き込んだ直後のカーソル位置は原文の手前のままになる。
    /// 応答時のカーソルが記録より原文の長さだけ後ろにあり、その直前に原文があれば、書き込みが反映されたものとして位置を改める。
    func reanchorIfCaretLagged(_ request: PendingRequest, in input: ReplacementInput) {
        guard request.kind == .first, let target = pendingTarget, target.requestID == request.id,
              let anchor, anchor.text == target.expectedText, anchor.end == target.selection.location else { return }
        let length = anchor.text.utf16.count
        let selection = input.selectedRange()
        guard selection.length == 0, selection.location == anchor.end + length,
              input.attributedSubstring(from: NSRange(location: anchor.end, length: length))?.string == anchor.text else { return }
        DiagnosticLog.record(.targetReanchored)
        self.anchor = ReplacementAnchor(end: selection.location, text: anchor.text)
        pendingTarget = PendingTarget(requestID: target.requestID, selection: selection,
                                      expectedText: target.expectedText, kind: target.kind)
    }

    /// ターミナルで動く全画面のアプリ(Claude Codeなど)は、行の折り返しなどで画面を描き直し、文字の位置番号がずれる。
    /// 応答待ちの間に打ったキーは入力先へ書かずに溜めているので、書き込んだ文字はカーソルの直前に残っているはずである。
    /// カーソルの直前に記録した文字列があれば、そこを置換位置として記録し直す。
    func reanchorAtCaret(_ request: PendingRequest, in input: ReplacementInput) {
        guard let target = pendingTarget, target.requestID == request.id, target.kind == request.kind,
              let anchor, anchor.text == target.expectedText else { return }
        let selection = input.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0,
              let span = wrappedSpan(of: anchor.text, endingAt: selection.location, in: input)
        else {
            DiagnosticLog.record(.reanchorUnavailable)
            return
        }
        DiagnosticLog.record(.targetReanchored)
        self.anchor = ReplacementAnchor(end: selection.location, text: anchor.text, span: span)
        pendingTarget = PendingTarget(requestID: target.requestID, selection: selection,
                                      expectedText: target.expectedText, kind: target.kind)
    }

    /// `end`の直前に`text`があれば、その文書上の長さを返す。ターミナルが折り返しで挟んだ改行と字下げも含める。
    private func wrappedSpan(of text: String, endingAt end: Int, in input: ReplacementInput) -> Int? {
        let length = text.utf16.count
        // 折り返しは1行ごとに数文字増えるだけなので、原文の2倍を読めば足りる。
        let start = max(0, end - length * 2)
        guard end >= length,
              let window = input.attributedSubstring(from: NSRange(location: start, length: end - start))?.string
        else { return nil }
        return WrappedText.suffixLength(of: text, in: window)
    }

    /// 記録した位置の文字列が一致しなかったとき、入力先が何を返したかを内容を出さずに記録する。
    /// 詳細設定時だけ範囲と返った文字数を出す。診断のために通常時の読み取りを増やさない。
    func reportTargetMismatch(in input: ReplacementInput) {
        guard DiagnosticLog.isDetailedEnabled else { return }
        guard let anchor, anchor.end >= anchor.span else {
            DiagnosticLog.record(.anchorMissing)
            return
        }
        let range = anchor.range
        guard let actual = input.attributedSubstring(from: range)?.string else {
            DiagnosticLog.record(.substringUnavailable)
            return
        }
        DiagnosticLog.record(.targetMismatch, counters: [range.location, range.length, actual.unicodeScalars.count])
    }

    /// 記録した位置に記録した文字列があるかを確かめる。なければ、カーソルの直前にあるかを確かめて記録し直す。
    ///
    /// ターミナルで動く全画面のアプリ(Claude Codeなど)は、置換したあとも入力欄を描き直し、文字の位置番号がずれる。
    /// 候補の出し直しや候補の選択のときには、記録した位置に変換結果が読めない。変換結果のあとに打った文字は
    /// 直前の変換を取り消す(`previous`を消す)ので、変換結果が残っていればカーソルの直前にあるはずである。
    /// 記録した文字列と違う文字列は置換しないという安全性は変わらない。
    func validatesAnchor(in input: ReplacementInput, expected: String) -> Bool {
        if anchorMatches(in: input, expected: expected) { return true }
        guard let anchor, anchor.text == expected else { return false }
        let selection = input.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0,
              let span = wrappedSpan(of: anchor.text, endingAt: selection.location, in: input) else { return false }
        DiagnosticLog.record(.targetReanchored)
        self.anchor = ReplacementAnchor(end: selection.location, text: anchor.text, span: span)
        return true
    }

    private func anchorMatches(in input: ReplacementInput, expected: String) -> Bool {
        guard let anchor,
              anchor.text == expected,
              anchor.end >= anchor.span else { return false }
        let range = anchor.range
        // 入力先によって、置換したあとのカーソルの形が違う。メモは末尾のカーソル、Chromeは選択範囲が残る。
        // どちらも「記録した位置に記録した文字列がまだある」ことに変わりはないので、両方を認める。
        let selection = input.selectedRange()
        let caretAtEnd = selection.location == anchor.end && selection.length == 0
        guard caretAtEnd || selection == range else {
            DiagnosticLog.record(.anchorRejected)
            return false
        }
        guard let actual = input.attributedSubstring(from: range)?.string else { return false }
        if anchor.span == anchor.text.utf16.count { return actual == anchor.text }
        // 折り返して表示された原文は、記録した長さのまま、改行と字下げを除いて一致することを確かめる。
        return WrappedText.suffixLength(of: anchor.text, in: actual) == anchor.span
    }

}
