import Foundation

/// In-memory numeric metadata only, never written to logs/preferences or sent to Decisions.
struct AmbientRangeReport: Equatable {
    let marked: NSRange
    let selection: NSRange

    var markedDescription: String { Self.describe(marked) }
    var selectionDescription: String { Self.describe(selection) }
    private static func describe(_ range: NSRange) -> String {
        let position = range.location == NSNotFound || range.location < 0 ? "不明" : String(range.location)
        let length = range.length < 0 ? "不明" : String(range.length)
        return "位置 \(position)、長さ \(length)"
    }
}

struct AmbientSourceReadReport: Equatable {
    let requestedLength: Int
    let returnedLength: Int?
    var returnedDescription: String { returnedLength.map { "\($0)" } ?? "取得不可" }
}

/// Fixed diagnostic text only: never includes input, application names or ranges.
enum AmbientObservationBlock: String, Error, CaseIterable {
    case queueFull = "自動判定の待機が多いため停止しました。手動変換を使うか、入力を区切ってください。"
    case secureInput = "機密入力保護が有効です。"
    case busy = "手動変換または候補操作中です。"
    case unsupportedText = "自動判定の対象外の文字列です。"
    case inputUnavailable = "有効な入力先を取得できません。"
    case frontmostMismatch = "入力先と最前面アプリの照合に失敗しました。"
    case markedUnavailable = "未確定範囲を取得できません。"
    case markedLengthMismatch = "未確定範囲と保持中の原文の長さが一致しません。"
    case selectionMismatch = "選択位置が未確定範囲の末尾・全体選択・相対末尾の条件と一致しません。"
    case sourceUnavailable = "未確定範囲の文字列を読み取れません。"
    case sourceMismatch = "未確定範囲の文字列と保持中の原文が一致しません。"
    case invalidObservation = "文字数または最新操作が自動判定の条件外です。"
    case targetChanged = "判定開始前に入力先または対象が変わりました。"
}

/// Read only the exact range of Sumibi's own marked source. The explicitly allowed IMK
/// unreadable-composition path must validate committed source before result replacement.
/// Never widen to surrounding text or perform an accessibility scrape.
struct AmbientInputSnapshot: Equatable {
    let source: String
    let marked: NSRange
    let selection: NSRange
    let requiresCommittedValidation: Bool

    /// Observed Codex shape: marked (22,13), selection (13,0). Only accept a relative
    /// end caret when it lies before the marked range, not an ambiguous caret inside it.
    var reportsRelativeEndCaret: Bool {
        selection.length == 0 && selection.location == marked.length
            && selection.location < marked.location
    }

    init?(source: String, input: any InputClient, allowUnreadableComposition: Bool = false) {
        guard case .success(let snapshot) = Self.capture(source: source, input: input,
            allowUnreadableComposition: allowUnreadableComposition) else { return nil }
        self = snapshot
    }

    private init(source: String, marked: NSRange, selection: NSRange, requiresCommittedValidation: Bool) {
        self.source = source
        self.marked = marked
        self.selection = selection
        self.requiresCommittedValidation = requiresCommittedValidation
    }

    static func capture(source: String, input: any InputClient,
                        allowUnreadableComposition: Bool = false,
                        onRanges: ((AmbientRangeReport) -> Void)? = nil,
                        onSelectionMismatch: ((NSRange, NSRange) -> Void)? = nil,
                        onSourceRead: ((AmbientRangeReport, Int?) -> Void)? = nil) -> Result<Self, AmbientObservationBlock> {
        let marked = input.markedRange()
        let selection = input.selectedRange()
        onRanges?(AmbientRangeReport(marked: marked, selection: selection))
        guard !source.isEmpty else { return .failure(.unsupportedText) }
        guard marked.location != NSNotFound, marked.location >= 0, marked.length >= 0,
              marked.location <= Int.max - marked.length else { return .failure(.markedUnavailable) }
        guard marked.length == source.utf16.count else { return .failure(.markedLengthMismatch) }
        // Accept exact known composition reports, not arbitrary selection. Keep the raw
        // ranges unchanged for all subsequent checks; never compare a normalized caret
        // with an unrelated range or silently accept an interior absolute caret.
        let endCaret = selection.length == 0 && selection.location == marked.location + marked.length
        let wholeComposition = selection == marked
        let relativeEnd = selection.length == 0 && selection.location == marked.length
            && selection.location < marked.location
        guard endCaret || wholeComposition || relativeEnd else {
            onSelectionMismatch?(marked, selection)
            return .failure(.selectionMismatch)
        }
        let actual = input.attributedSubstring(from: marked)?.string
        onSourceRead?(AmbientRangeReport(marked: marked, selection: selection), actual?.utf16.count)
        if let actual {
            guard actual == source else { return .failure(.sourceMismatch) }
        } else if !allowUnreadableComposition { return .failure(.sourceUnavailable) }
        return .success(Self(source: source, marked: marked, selection: selection,
                             requiresCommittedValidation: actual == nil))
    }

    func matches(_ input: any InputClient) -> Bool {
        validationFailure(in: input) == nil
    }

    func validationFailure(in input: any InputClient,
                           onSourceRead: ((Int?) -> Void)? = nil) -> AmbientObservationBlock? {
        guard input.markedRange() == marked, input.selectedRange() == selection else { return .targetChanged }
        let actual = input.attributedSubstring(from: marked)?.string
        onSourceRead?(actual?.utf16.count)
        if let actual { return actual == source ? nil : .sourceMismatch }
        return requiresCommittedValidation ? nil : .sourceUnavailable
    }
}
