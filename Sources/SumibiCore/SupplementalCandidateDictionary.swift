import Foundation

/// Local additions only. The caller must invoke this after a successful alternatives
/// response; initial/automatic conversion and the outgoing request stay unchanged.
public struct SupplementalCandidateDictionary: Sendable {
    private let symbols: [String: [String]]
    private let homophones: HomophoneDictionary?

    public init(symbolTSV: String = "", homophones: HomophoneDictionary? = nil) {
        var entries: [String: [String]] = [:]
        for line in symbolTSV.split(separator: "\n") where !line.hasPrefix("# ") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { continue }
            entries[Self.key(fields[0]), default: []].append(contentsOf: fields.dropFirst().filter { !$0.isEmpty })
        }
        symbols = entries
        self.homophones = homophones
    }

    public func supplement(_ result: ConversionResult, source: String, maximumAdded: Int = 10) -> ConversionResult {
        guard maximumAdded > 0 else { return result }
        let key = Self.key(source)
        let custom = ["ten", "nakaguro", "."].contains(key) ? ["・"] : []
        let homophoneValues = homophones?.supplement(result.candidates, maximumAdded: maximumAdded)
            .dropFirst(result.candidates.count) ?? []
        var candidates = result.candidates
        var seen = Set(candidates)
        seen.insert(source)
        var added: Set<String> = []
        for value in custom + (symbols[key] ?? []) + homophoneValues where seen.insert(value).inserted {
            candidates.append(value)
            added.insert(value)
            if added.count == maximumAdded { break }
        }
        return ConversionResult(
            candidates: candidates,
            model: result.model,
            dictionaryCandidates: result.dictionaryCandidates.union(added),
            usage: result.usage
        )
    }

    /// ASCII case only. No trimming, substring search, or compatibility normalization:
    /// e.g. circled numbers must not become ordinary digits.
    private static func key(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            (65...90).contains($0.value) ? UnicodeScalar($0.value + 32)! : $0
        }))
    }
}
