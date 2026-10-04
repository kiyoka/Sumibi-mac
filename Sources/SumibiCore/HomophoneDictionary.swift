import Foundation

/// SudachiDict Coreから生成した、読みと表記候補の索引。
/// LLM候補内に単語全体のひらがな表記があるときだけ、Emacs版と同様に辞書候補を末尾へ補う。
public struct HomophoneDictionary: Sendable {
    private let entries: [String: [String]]

    public init(contentsOf url: URL) throws {
        self.init(tsv: try String(contentsOf: url, encoding: .utf8))
    }

    public init(tsv: String) {
        var parsed: [String: [String]] = [:]
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3, !columns[0].isEmpty else { continue }
            parsed[columns[0]] = Array(columns.dropFirst())
        }
        entries = parsed
    }

    /// LLMの順序を保ち、重複を除いて辞書候補を最大10件だけ追加する。
    public func supplement(_ llmCandidates: [String], maximumAdded: Int = 10) -> [String] {
        guard maximumAdded > 0,
              let reading = llmCandidates.first(where: Self.isHiraganaWord),
              let dictionaryCandidates = entries[reading] else { return llmCandidates }
        var combined = llmCandidates
        var seen = Set(llmCandidates)
        var added = 0
        for candidate in dictionaryCandidates where !seen.contains(candidate) {
            combined.append(candidate)
            seen.insert(candidate)
            added += 1
            if added == maximumAdded { break }
        }
        return combined
    }

    private static func isHiraganaWord(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (0x3041 ... 0x3096).contains($0.value) || $0.value == 0x30FC
        }
    }
}
