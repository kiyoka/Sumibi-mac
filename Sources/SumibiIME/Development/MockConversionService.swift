#if SUMIBI_DEVELOPMENT
import Foundation
import SumibiCore

/// Compiled only into an explicitly opted-in development build. Never uses the network.
struct MockConversionService: ConversionService {
    private let delay: TimeInterval
    private let succeeds: Bool

    init(delay: TimeInterval = 0.6, succeeds: Bool = true) {
        self.delay = delay
        self.succeeds = succeeds
    }

    func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        try ConversionLimit.check(request)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard succeeds else { throw ConversionError.network("模擬失敗") }
        switch request.mode {
        case .first:
            return ConversionResult(candidates: [Self.mockFirst(request.source)])
        case .alternatives:
            let base = request.currentConversion ?? Self.mockFirst(request.source)
            return ConversionResult(candidates: [base] + (1 ... 10).map { "候補\($0)・\(base)" })
        }
    }

    private static func mockFirst(_ source: String) -> String {
        switch source.lowercased() {
        case "ohayou": "おはよう"
        case "arigatou": "ありがとう"
        default: "【\(source)】"
        }
    }
}
#endif
