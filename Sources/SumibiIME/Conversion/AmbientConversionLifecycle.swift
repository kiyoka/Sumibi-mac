import Foundation
import SumibiCore

/// Main-thread state shared across IMK recreation. Fixed windows retain every eligible
/// observation; only a current target can convert. Input itself is never queued.
final class AmbientConversionLifecycle {
    enum Phase: String { case idle = "待機", collecting = "入力状態を集約中", judging = "Decisions判定中", converting = "日本語変換中", verifyingSource = "確定した原文を確認中", verifying = "変換結果を確認中" }
    enum Verification { case waiting, confirmed, cancelled }
    enum SourceResolution { case waiting, applied, verifyingResult, failed(AmbientDeliveryFailure), cancelled }
    struct SourceContinuation {
        let poll: (_ deadline: TimeInterval) -> SourceResolution
        let cancel: () -> Void
    }
    private enum DeliveryContinuation { case none, source(SourceContinuation, deadline: TimeInterval), result }
    struct Target {
        let observation: DecisionsObservation
        let isCurrent: () -> Bool
        let apply: (ConversionResult) -> Bool
        let verify: (() -> Verification)?
        let sourceContinuation: (() -> SourceContinuation?)?
        let onAccepted: () -> Void

        init(observation: DecisionsObservation, isCurrent: @escaping () -> Bool,
             apply: @escaping (ConversionResult) -> Bool, verify: (() -> Verification)? = nil,
             sourceContinuation: (() -> SourceContinuation?)? = nil,
             onAccepted: @escaping () -> Void = {}) {
            self.observation = observation; self.isCurrent = isCurrent
            self.apply = apply; self.verify = verify
            self.sourceContinuation = sourceContinuation
            self.onAccepted = onAccepted
        }
    }
    private struct Pending {
        let target: Target
        let generation: Int
        let settings: DecisionsSettings
    }
    private let store: DecisionsSettingsStore
    private let prepare: (DecisionsObservation, DecisionsSettings) throws -> AmbientWork
    private let feedback: ConversionFeedback
    private let dismissCue: () -> Void
    private var generation = 0
    private var collecting: [Pending] = []
    private var ready: [[Pending]] = []
    private var latest: Pending?
    private var deadline: TimeInterval?
    private var windowToken = 0
    private let now: () -> TimeInterval
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var ownsBusyIndicator = false
    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var lastObservationBlock: AmbientObservationBlock?
    private(set) var lastObservationRanges: AmbientRangeReport?
    private(set) var lastSourceReadReport: AmbientSourceReadReport?
    private(set) var lastObservationDetails: String?
    private(set) var lastDeliveryFailure: AmbientDeliveryFailure?
    private(set) var lastCommitReport: AmbientCommitReport?
    private(set) var debugTextEnabled = false
    private(set) var lastCommitText: AmbientCommitTextReport?
    private(set) var lastResultText: AmbientResultTextReport?
    private(set) var lastObservationText: AmbientObservationTextReport?
    private var lastResultReadback: ConversionResultReadback?
    private var expectedResultUTF16: Int?
    var lastDecision: DecisionsDecisionReport? { feedback.lastDecisionsDecision }

    init(store: DecisionsSettingsStore = DecisionsSettingsStore(), feedback: ConversionFeedback = ConversionFeedback(),
         prepare: ((DecisionsObservation, DecisionsSettings) throws -> AmbientWork)? = nil,
         dismissCue: @escaping () -> Void = {},
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.feedback = feedback
        self.dismissCue = dismissCue
        self.now = now
        self.prepare = prepare ?? { try DecisionsCoordinator(store: store).prepare(observation: $0, settings: $1) }
    }

    func observe(_ target: Target) {
        dismissCue()
        lastObservationText = nil
        lastObservationBlock = nil
        lastObservationRanges = nil
        lastSourceReadReport = nil
        lastObservationDetails = nil
        generation &+= 1
        let settings = store.load()
        guard settings.permitsSending, target.observation.text.count <= settings.maximumCharacters else {
            stop()
            return
        }
        if let previous = latest, previous.settings != settings { stop() }
        // Check the deadline on input too: an overdue UI timer must not extend a window.
        if let deadline, now() >= deadline { sealWindow(drain: false) }
        let item = Pending(target: target, generation: generation, settings: settings)
        latest = item
        let queued = collecting.count + ready.reduce(0) { $0 + $1.count }
        // Bound retained input while transport is slow. Never silently discard a prefix
        // and apply its score to another target; stop and allow manual conversion.
        guard queued < 256 else { skipObservation(.queueFull); return }
        let reservedBatches = ready.count + (collecting.count + 1 + DecisionsClient.maximumBatchSize - 1) / DecisionsClient.maximumBatchSize
        guard store.calls + reservedBatches <= settings.maximumCalls else {
            stop(); report(DecisionsError.requestLimit); return
        }
        if settings.batchWindowMilliseconds == 0 {
            ready.append([item]); pump(); return
        }
        collecting.append(item)
        if deadline == nil {
            deadline = now() + Double(settings.batchWindowMilliseconds) / 1_000
            windowToken &+= 1
            let token = windowToken
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(settings.batchWindowMilliseconds) * 1_000_000) }
                catch { return }
                await MainActor.run { [weak self] in
                    guard let self, self.windowToken == token else { return }
                    self.sealWindow()
                }
            }
        }
        if task == nil { phase = .collecting }
        pump()
    }

    /// Keep the request slot until cancelled transport finishes: do not overlap requests.
    func stop() {
        dismissCue()
        generation &+= 1
        collecting = []; ready = []; latest = nil; deadline = nil
        windowToken &+= 1
        timer?.cancel()
        timer = nil
        task?.cancel()
        endBusy()
        phase = .idle
    }

    func resetCalls() {
        stop()
        store.resetCalls()
        lastError = nil
    }

    func settingsChanged() {
        stop()
        feedback.clearDecisionsDecision()
        lastError = nil
        lastObservationBlock = nil
        lastObservationRanges = nil
        lastSourceReadReport = nil
        lastObservationDetails = nil
        lastDeliveryFailure = nil
        lastCommitReport = nil
        lastCommitText = nil
        lastResultText = nil
        lastObservationText = nil
        lastResultReadback = nil; expectedResultUTF16 = nil
    }

    func skipObservation(_ reason: AmbientObservationBlock, ranges: AmbientRangeReport? = nil,
                         sourceRead: AmbientSourceReadReport? = nil,
                         sourceCharacters: Int? = nil, sourceUTF16: Int? = nil,
                         debugText: AmbientObservationTextReport? = nil) {
        stop()
        lastObservationText = debugTextEnabled && (reason == .sourceMismatch || reason == .sourceUnavailable)
            ? debugText : nil
        lastObservationBlock = reason
        lastObservationRanges = ranges
        lastSourceReadReport = sourceRead
        lastObservationDetails = nil
        if let sourceCharacters, let sourceUTF16 {
            var details = "対象 \(sourceCharacters)文字／UTF-16 \(sourceUTF16)"
            if let sourceRead {
                details += "、読取要求 \(sourceRead.requestedLength)／取得 \(sourceRead.returnedDescription)（UTF-16）"
            } else if let ranges {
                details += "、未確定範囲の長さ \(ranges.marked.length)（UTF-16）"
            }
            lastObservationDetails = details
        }
        // IMK may briefly expose older text/ranges while typing. No conversion has
        // been applied here: keep this as a quiet skip, never an error/caret cue.
        // The menu/settings retain the reason and counts for long-input diagnosis.
    }

    func beginDeliveryAttempt() {
        lastObservationText = nil
        lastDeliveryFailure = nil; lastCommitReport = nil; lastCommitText = nil; lastResultText = nil
        lastResultReadback = nil; expectedResultUTF16 = nil
    }
    func recordDeliveryFailure(_ failure: AmbientDeliveryFailure) { lastDeliveryFailure = failure }
    func recordCommitReport(_ report: AmbientCommitReport) { lastCommitReport = report }
    func recordResultReadback(_ readback: ConversionResultReadback, expectedUTF16: Int) {
        lastResultReadback = readback; expectedResultUTF16 = expectedUTF16
    }
    func setDebugTextEnabled(_ enabled: Bool) {
        debugTextEnabled = enabled; lastCommitText = nil; lastResultText = nil
        lastObservationText = nil
    }
    func recordCommitText(_ report: AmbientCommitTextReport) {
        guard debugTextEnabled else { return }
        lastCommitText = report
    }
    func recordResultText(_ report: AmbientResultTextReport) {
        guard debugTextEnabled else { return }
        lastResultText = report
    }

    private func current(_ item: Pending, work: AmbientWork? = nil) -> Bool {
        item.generation == generation && store.load() == item.settings
            && item.target.isCurrent() && (work?.remainsAuthorized() ?? true)
    }

    private func sealWindow(drain: Bool = true) {
        timer?.cancel(); timer = nil; deadline = nil; windowToken &+= 1
        while !collecting.isEmpty {
            let size = min(DecisionsClient.maximumBatchSize, collecting.count)
            ready.append(Array(collecting.prefix(size)))
            collecting.removeFirst(size)
        }
        if drain { pump() }
    }

    private func pump() {
        guard task == nil, !ready.isEmpty else { return }
        guard let latest, current(latest) else { stop(); lastObservationBlock = .targetChanged; return }
        let batch = ready.removeFirst()
        let item = batch.last!
        let works: [AmbientWork]
        do {
            guard store.calls < item.settings.maximumCalls else { throw DecisionsError.requestLimit }
            works = try batch.map { try prepare($0.target.observation, $0.settings) }
            guard works.allSatisfy({ $0.remainsAuthorized() }), store.load() == item.settings else { stop(); return }
            guard store.reserve(limit: item.settings.maximumCalls) else { throw DecisionsError.requestLimit }
        } catch { stop(); report(error); return }
        let work = works.last!
        ownsBusyIndicator = true
        feedback.begin()
        phase = .judging
        DiagnosticLog.record(.decisionsStarted)
        task = Task { [weak self] in
            var sourceWait: SourceContinuation?
            do {
                guard await MainActor.run(body: { [weak self] in self?.store.load() == item.settings && work.remainsAuthorized() }) else {
                    throw CancellationError()
                }
                let observations = batch.map { $0.target.observation }
                let answers: [DecisionsAnswer]
                if let scoreBatch = work.scoreBatch { answers = try await scoreBatch(observations) }
                else {
                    var values: [DecisionsAnswer] = []
                    for observation in observations { values.append(.probability(try await work.score(observation))) }
                    answers = values
                }
                try Task.checkCancellation()
                guard answers.count == batch.count else { throw DecisionsError.invalidResponse }
                let chosen = await MainActor.run { [weak self] () -> Int? in
                    guard let self else { return nil }
                    for index in batch.indices.reversed() where self.current(batch[index], work: works[index]) {
                        if case .refused = answers[index] { self.report(DecisionsError.refused); return nil }
                        return index
                    }
                    DiagnosticLog.record(.decisionsDiscarded)
                    return nil
                }
                guard let chosen else { throw CancellationError() }
                let item = batch[chosen]
                let work = works[chosen]
                let observation = observations[chosen]
                guard case .probability(let score) = answers[chosen] else { throw DecisionsError.refused }
                guard score.isFinite, (0...1).contains(score) else { throw DecisionsError.invalidResponse }
                let mayConvert = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.current(item, work: work) else {
                        DiagnosticLog.record(.decisionsDiscarded)
                        return false
                    }
                    self.lastError = nil
                    self.feedback.recordDecisionsDecision(score: score, threshold: item.settings.threshold)
                    DiagnosticLog.record(.decisionsJudged)
                    guard score >= item.settings.threshold else { return false }
                    self.phase = .converting
                    item.target.onAccepted()
                    return true
                }
                if mayConvert {
                    let result = await work.convert()
                    try Task.checkCancellation()
                    let continuation = await MainActor.run { [weak self] () -> DeliveryContinuation in
                        guard let self, self.current(item, work: work) else {
                            DiagnosticLog.record(.decisionsDiscarded)
                            return .none
                        }
                        switch result {
                        case .success(let result):
                            let decorated = AmbientText.decorate(result, source: observation.text)
                            guard !decorated.candidates.isEmpty else { self.report(ConversionError.emptyResponse); return .none }
                            if item.target.apply(decorated) {
                                self.didApply()
                            } else if self.lastDeliveryFailure == nil, let pendingSource = item.target.sourceContinuation?() {
                                self.phase = .verifyingSource
                                DiagnosticLog.record(.committedSourceWaiting)
                                return .source(pendingSource, deadline: self.now() + 0.5)
                            } else if self.lastDeliveryFailure == nil, item.target.verify != nil {
                                self.phase = .verifying
                                return .result
                            } else {
                                if let failure = self.lastDeliveryFailure, failure.isCancellation {
                                    DiagnosticLog.record(.decisionsDiscarded)
                                    return .none
                                }
                                self.reportDelivery(self.lastDeliveryFailure, observation: observation)
                            }
                        case .failure(let error): self.report(error)
                        }
                        return .none
                    }
                    var needsVerification = false
                    switch continuation {
                    case .none: break
                    case .result: needsVerification = true
                    case .source(let pendingSource, let deadline):
                        sourceWait = pendingSource
                        for attempt in 1...5 {
                            try await Task.sleep(nanoseconds: 100_000_000)
                            try Task.checkCancellation()
                            let resolution = await MainActor.run { [weak self] () -> SourceResolution in
                                guard let self, item.generation == self.generation,
                                      self.store.load() == item.settings, work.remainsAuthorized() else { return .cancelled }
                                // An overdue UI task must not extend the source-read window.
                                guard self.now() < deadline else {
                                    pendingSource.cancel()
                                    self.lastDeliveryFailure = .committedSourceUnavailable
                                    self.reportDelivery(.committedSourceUnavailable, observation: observation)
                                    return .failed(.committedSourceUnavailable)
                                }
                                DiagnosticLog.record(.committedSourceRetried, counters: [attempt])
                                let outcome = pendingSource.poll(deadline)
                                switch outcome {
                                case .waiting where attempt == 5:
                                    pendingSource.cancel()
                                    self.lastDeliveryFailure = .committedSourceUnavailable
                                    self.reportDelivery(.committedSourceUnavailable, observation: observation)
                                    return .failed(.committedSourceUnavailable)
                                case .failed(let failure):
                                    pendingSource.cancel()
                                    self.lastDeliveryFailure = failure
                                    if failure.isCancellation { DiagnosticLog.record(.decisionsDiscarded) }
                                    else { self.reportDelivery(failure, observation: observation) }
                                case .applied:
                                    DiagnosticLog.record(.committedSourceConfirmed)
                                    self.didApply()
                                case .verifyingResult:
                                    DiagnosticLog.record(.committedSourceConfirmed)
                                    self.phase = .verifying
                                case .cancelled: DiagnosticLog.record(.decisionsDiscarded)
                                default: break
                                }
                                return outcome
                            }
                            if case .verifyingResult = resolution { needsVerification = true }
                            if case .waiting = resolution { continue }
                            break
                        }
                    }
                    if needsVerification {
                        // Five read-only polls over at most 0.5 seconds. The paid pipeline
                        // is not restarted, and editable input is never queued or blocked.
                        for attempt in 1...5 {
                            try await Task.sleep(nanoseconds: 100_000_000)
                            try Task.checkCancellation()
                            let finished = await MainActor.run { [weak self] () -> Bool in
                                guard let self, item.generation == self.generation,
                                      self.store.load() == item.settings, work.remainsAuthorized(),
                                      let verify = item.target.verify else { return true }
                                switch verify() {
                                case .confirmed: self.didApply(); return true
                                case .cancelled:
                                    DiagnosticLog.record(.decisionsDiscarded)
                                    return true
                                case .waiting:
                                    guard attempt == 5 else { return false }
                                    self.lastDeliveryFailure = .resultUnavailable
                                    self.lastError = AmbientDeliveryFailure.resultUnavailable.rawValue
                                    let notice = if let readback = self.lastResultReadback, let expected = self.expectedResultUTF16 {
                                        ConversionNotice.resultConfirmation(readback, sourceCharacters: observation.text.count,
                                            sourceUTF16: observation.text.utf16.count, expectedUTF16: expected)
                                    } else { ConversionNotice(title: "変換結果を確認できませんでした",
                                        message: "置換後の変換結果を時間内に読み取れませんでした。",
                                        advice: "入力欄の文字を確認してください。変換済みの場合は再変換せず、エラー表示を解除してください。原因は未特定です。",
                                        stage: ConversionDeliveryStage.resultVerification.rawValue,
                                        details: "対象 \(observation.text.count)文字／UTF-16 \(observation.text.utf16.count)、確認期限 0.5秒") }
                                    self.feedback.report(notice)
                                    DiagnosticLog.record(.deliveryUnavailable)
                                    return true
                                }
                            }
                            if finished { break }
                        }
                    }
                }
            } catch is CancellationError {
                // Stale results and already-reported refusals are not network errors.
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        guard let self, self.current(item, work: work) else { return }
                        self.report(error)
                    }
                }
            }
            await MainActor.run { [weak self, sourceWait] in
                sourceWait?.cancel()
                guard let self else { return }
                self.task = nil
                self.endBusy()
                self.phase = self.collecting.isEmpty ? .idle : .collecting
                self.pump()
            }
        }
    }

    private func endBusy() {
        if ownsBusyIndicator { feedback.finish(); ownsBusyIndicator = false }
    }

    private func didApply() {
        lastObservationText = nil
        lastError = nil
        lastDeliveryFailure = nil
        lastCommitReport = nil
        lastCommitText = nil
        lastResultText = nil
        DiagnosticLog.record(.decisionsApplied)
    }

    private func reportDelivery(_ failure: AmbientDeliveryFailure?, observation: DecisionsObservation) {
        var notice = failure.map {
            ConversionNotice.ambientDelivery($0, sourceCharacters: observation.text.count,
                sourceUTF16: observation.text.utf16.count)
        } ?? ConversionNotice.delivery(.trackingUnavailable, stage: .replacement,
            sourceCharacters: observation.text.count, sourceUTF16: observation.text.utf16.count)
        if let report = lastCommitReport {
            notice.details = (notice.details ?? "") + "、記録範囲の読取 \(report.originalReadLength.map(String.init) ?? "不可")／\(report.originalRange.length)（\(report.originalComparison.rawValue)）、カーソル直前 \(report.caretReadLength.map(String.init) ?? "不可")（\(report.caretComparison.rawValue)）"
        }
        lastError = notice.message
        feedback.report(notice)
        DiagnosticLog.record(.deliveryUnavailable)
    }

    private func report(_ error: Error) {
        if let error = error as? DecisionsError {
            lastError = error.message
            feedback.report(ConversionNotice(title: "Decisions自動変換を実行できません",
                message: error.message, advice: "設定・通信・判定回数を確認してください。手動変換は引き続き使えます。",
                stage: "Decisions判定・設定／通信"))
            DiagnosticLog.decisionsFailed(error)
        } else {
            let safe = ConversionNotice.failure((error as? ConversionError) ?? .network(""))
            lastError = safe.message
            feedback.report(safe)
            DiagnosticLog.conversionFailed((error as? ConversionError) ?? .network(""))
        }
    }

    deinit { task?.cancel(); timer?.cancel() }
}
