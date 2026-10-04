import Foundation
import SumibiCore
import os

private let diag = Logger(subsystem: "org.sumibi.inputmethod.Sumibi", category: "diag")

/// A result may outlive the controller which requested it, until a live client is available.
enum PendingOutcome: Equatable {
    case first(String)
    case alternatives(ConversionResult)
    case failure(ConversionError)
}

/// Main-thread owner of one conversion task, its ready result and delivery retry timer.
/// InputSession owns request IDs/queued keys; this object never writes to an input client.
/// Injected conversion work allows cancellation/races to be tested without real API calls.
final class ConversionLifecycle {
    typealias Convert = (ConversionRequest) async -> Result<ConversionResult, ConversionError>
    private let session: InputSession
    private let convert: Convert
    private let feedback: ConversionFeedback?
    private var task: Task<Void, Never>?
    private var timer: DispatchWorkItem?
    private var requestID: Int?
    private var outcome: PendingOutcome?
    private(set) var readyAt: Date?
    private(set) var retryCount = 0

    init(session: InputSession, feedback: ConversionFeedback? = nil,
         convert: @escaping Convert = { await ConversionCoordinator().convert($0) }) {
        self.session = session
        self.feedback = feedback
        self.convert = convert
    }

    func start(id: Int, request: ConversionRequest, onReady: @escaping (Int) -> Void) {
        cancel()
        requestID = id
        feedback?.begin()
        let convert = self.convert
        task = Task { [weak self] in
            let result = await convert(request)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.requestID == id, self.session.pending?.id == id else { return }
                switch result {
                case .success(let result):
                    switch request.mode {
                    case .first: self.outcome = .first(result.candidates.first ?? "")
                    case .alternatives: self.outcome = .alternatives(result)
                    }
                    diag.notice("conversion succeeded id=\(id) candidates=\(result.candidates.count)")
                case .failure(let error):
                    self.outcome = .failure(error)
                    self.feedback?.report(.failure(error))
                    diag.notice("conversion failed id=\(id) retryable=\(error.isRetryable)")
                }
                self.readyAt = Date()
                onReady(id)
            }
        }
    }

    /// Consume exactly once, before draining queued keys can start the next request.
    func takeOutcome(id: Int) -> PendingOutcome? {
        guard requestID == id, let result = outcome else { return nil }
        cancel()
        return result
    }

    func scheduleFinish(id: Int, delay: TimeInterval, retry: Bool, finish: @escaping (Int) -> Void) {
        guard requestID == id else { return }
        if !retry { retryCount = 0 }
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == id, self.session.pending?.id == id else { return }
            diag.notice("finish timer id=\(id) retry=\(self.retryCount)")
            finish(id)
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Preserve the previous limit: 240 retries at 0.25 seconds, then stop safely.
    func recordUnavailableClient() -> Bool {
        retryCount += 1
        return retryCount <= 240
    }

    func cancel() {
        feedback?.finish()
        timer?.cancel()
        timer = nil
        task?.cancel()
        task = nil
        requestID = nil
        outcome = nil
        readyAt = nil
        retryCount = 0
    }

    deinit {
        timer?.cancel()
        task?.cancel()
    }
}
