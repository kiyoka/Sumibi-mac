import Foundation

/// Explicit UI debug opt-in only. Memory-only; never emit/persist these strings.
struct AmbientCommitTextReport: Equatable {
    let source: String
    let atOriginal: String?
    let atCaret: String?
}

/// Same opt-in lifetime as original text. Captured immediately after replacement,
/// before a failed verification clears tracking state. No retries or client writes.
struct AmbientResultTextReport: Equatable {
    let expected: String
    let range: NSRange?
    let selection: NSRange
    let actual: String?
    let caretRange: NSRange?
    let atCaret: String?
    let stateMatches: Bool

    static func capture(expected: String, range: NSRange?, actual: String?,
                        stateMatches: Bool, input: any InputClient) -> Self {
        let selection = input.selectedRange()
        let length = expected.utf16.count
        let caretRange = selection.location != NSNotFound && selection.length == 0 && selection.location >= length
            ? NSRange(location: selection.location - length, length: length) : nil
        let atCaret = caretRange.flatMap {
            $0 == range && stateMatches ? actual : input.attributedSubstring(from: $0)?.string
        }
        return Self(expected: expected, range: range, selection: selection, actual: actual,
                    caretRange: caretRange, atCaret: atCaret, stateMatches: stateMatches)
    }
}

/// Diagnostic metadata only; never retain source/read strings, emit logs or persist.
struct AmbientCommitReport: Equatable {
    enum Comparison: String {
        case unavailable = "取得不可"
        case empty = "空文字"
        case equal = "一致"
        case caseOnly = "大文字・小文字だけが相違"
        case differentLength = "長さが相違"
        case different = "同じ長さで内容が相違"
    }
    let originalRange: NSRange
    let selection: NSRange
    let originalReadLength: Int?
    let originalComparison: Comparison
    let caretRange: NSRange?
    let caretReadLength: Int?
    let caretComparison: Comparison

    init(source: String, originalRange: NSRange, input: any InputClient,
         captureText: ((AmbientCommitTextReport) -> Void)? = nil) {
        self.originalRange = originalRange
        selection = input.selectedRange()
        let atOriginal = input.attributedSubstring(from: originalRange)?.string
        originalReadLength = atOriginal?.utf16.count
        originalComparison = Self.compare(atOriginal, source: source)
        let length = source.utf16.count
        let atCaret: String?
        if selection.location != NSNotFound, selection.length == 0, selection.location >= length {
            let range = NSRange(location: selection.location - length, length: length)
            caretRange = range
            atCaret = range == originalRange ? atOriginal : input.attributedSubstring(from: range)?.string
            caretReadLength = atCaret?.utf16.count
            caretComparison = Self.compare(atCaret, source: source)
        } else {
            caretRange = nil
            caretReadLength = nil
            caretComparison = .unavailable
            atCaret = nil
        }
        captureText?(AmbientCommitTextReport(source: source, atOriginal: atOriginal, atCaret: atCaret))
    }

    private static func compare(_ actual: String?, source: String) -> Comparison {
        guard let actual else { return .unavailable }
        if actual == source { return .equal }
        if actual.isEmpty { return .empty }
        if actual.utf16.count != source.utf16.count { return .differentLength }
        if actual.caseInsensitiveCompare(source) == .orderedSame { return .caseOnly }
        return .different
    }
}
