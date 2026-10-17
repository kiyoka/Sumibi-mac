import Foundation

/// Manual delivery's read-only check. Never retries conversion or writes to a client.
/// A nil read means input/route/activity changed: cancellation is intentionally silent.
final class ConversionResultVerifier {
    private let feedback: ConversionFeedback
    private var task: Task<Void, Never>?
    private var generation = 0

    init(feedback: ConversionFeedback) { self.feedback = feedback }

    func start(sourceCharacters: Int, sourceUTF16: Int, expectedUTF16: Int,
               read: @escaping () -> ConversionResultReadback?) {
        cancel()
        guard let immediate = read(), immediate != .matching else { return }
        let current = generation
        task = Task { [weak self] in
            for attempt in 1...5 {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                let finished = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.generation == current, let actual = read() else { return true }
                    if actual == .matching { return true }
                    guard attempt == 5 else { return false }
                    self.feedback.report(.resultConfirmation(actual, sourceCharacters: sourceCharacters,
                        sourceUTF16: sourceUTF16, expectedUTF16: expectedUTF16))
                    DiagnosticLog.record(.deliveryUnavailable)
                    return true
                }
                if finished { break }
            }
        }
    }

    func cancel() { generation &+= 1; task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
