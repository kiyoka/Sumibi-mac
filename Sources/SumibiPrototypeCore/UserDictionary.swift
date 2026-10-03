import Foundation

public struct UserDictionaryEntry: Equatable, Sendable {
    public let reading: String
    public let replacement: String

    public init(reading: String, replacement: String) {
        self.reading = reading
        self.replacement = replacement
    }
}

public struct UserDictionaryValidationError: Equatable, Identifiable, Sendable {
    public let lineNumber: Int?
    public let reason: String
    public let line: String?

    public var id: String { "\(lineNumber.map(String.init) ?? "dictionary"):\(reason):\(line ?? "")" }
}

public struct UserDictionaryValidationResult: Equatable, Sendable {
    public let entries: [UserDictionaryEntry]
    public let errors: [UserDictionaryValidationError]
    public var isValid: Bool { errors.isEmpty }
}

/// iOS版と同じ「よみ = 変換後」形式を、macOS版で独立して検証する。
public enum UserDictionary {
    public static let maximumEntryCount = 100
    public static let maximumCharacterCount = 2_000

    public static func validate(_ text: String) -> UserDictionaryValidationResult {
        var entries: [UserDictionaryEntry] = []
        var errors: [UserDictionaryValidationError] = []
        var firstLineByReading: [String: Int] = [:]

        for (offset, substring) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = String(substring).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let separator = line.firstIndex(of: "=") else {
                errors.append(.init(lineNumber: lineNumber, reason: "区切りの「=」がありません", line: line))
                continue
            }

            let reading = line[..<separator].trimmingCharacters(in: .whitespaces)
            let replacement = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            var invalid = false
            if reading.isEmpty {
                errors.append(.init(lineNumber: lineNumber, reason: "よみが空です", line: line))
                invalid = true
            } else if reading.contains(where: { $0.isASCII && $0.isUppercase }) {
                errors.append(.init(lineNumber: lineNumber, reason: "よみに大文字は使えません", line: line))
                invalid = true
            } else if reading.contains(where: { !$0.isASCII || $0.isWhitespace || !$0.isASCIIPrintable }) {
                errors.append(.init(lineNumber: lineNumber, reason: "よみにはローマ字と記号だけを使えます", line: line))
                invalid = true
            }
            if replacement.isEmpty {
                errors.append(.init(lineNumber: lineNumber, reason: "変換後が空です", line: line))
                invalid = true
            }
            if !reading.isEmpty, let firstLine = firstLineByReading[reading] {
                errors.append(.init(lineNumber: lineNumber,
                                    reason: "よみ「\(reading)」が\(firstLine)行目と重複しています", line: line))
                invalid = true
            } else if !reading.isEmpty {
                firstLineByReading[reading] = lineNumber
            }
            if !invalid { entries.append(.init(reading: reading, replacement: replacement)) }
        }

        let nonemptyLineCount = text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        if nonemptyLineCount > maximumEntryCount {
            errors.append(.init(lineNumber: nil, reason: "登録が100件を超えています（\(nonemptyLineCount)件）", line: nil))
        }
        if text.count > maximumCharacterCount {
            errors.append(.init(lineNumber: nil, reason: "2,000文字を超えています（\(text.count)文字）", line: nil))
        }
        return .init(entries: entries, errors: errors)
    }
}

private extension Character {
    var isASCIIPrintable: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        return (0x21 ... 0x7E).contains(scalar.value)
    }
}
