import XCTest
import SumibiCore
@testable import SumibiIME

final class AmbientConversionLifecycleTests: XCTestCase {
    @MainActor
    private func fixture(enabled: Bool = true) throws -> AmbientFixture {
        try AmbientFixture(enabled: enabled)
    }

    @MainActor
    private func wait(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Mock operation did not complete")
    }

    @MainActor
    func testDefaultOffDoesNotPrepareOrReserveCalls() throws {
        let f = try fixture(enabled: false)
        var prepared = 0
        let life = f.lifecycle { _, _ in prepared += 1; throw DecisionsError.missingKey }
        life.observe(f.target("a"))
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(f.store.calls, 0)
        XCTAssertEqual(life.phase, .idle)
    }

    @MainActor
    func testDelayedResultConfirmationDoesNotRepeatPaidWorkOrReportPrematureFailure() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        var writes = 0
        var reads = 0
        life.observe(.init(observation: DecisionsObservation(text: "sample", latestKey: "e")!,
            isCurrent: { f.targetValid }, apply: { _ in writes += 1; return false },
            verify: { reads += 1; return reads == 3 ? .confirmed : .waiting }))
        await wait { life.phase == .verifying }
        XCTAssertNil(life.lastError)
        XCTAssertNil(f.feedback.notice)
        await wait { life.phase == .idle }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(f.converted, 1)
        XCTAssertEqual(f.store.calls, 1)
        XCTAssertNil(life.lastError)
        XCTAssertNil(life.lastDeliveryFailure)
        XCTAssertNil(f.feedback.notice)
    }

    @MainActor
    func testDelayedResultConfirmationTimesOutWithAccurateNoticeWithoutReapplying() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        var reads = 0
        var writes = 0
        life.observe(.init(observation: DecisionsObservation(text: "sample", latestKey: "e")!,
            isCurrent: { true }, apply: { _ in writes += 1; return false },
            verify: { reads += 1; return .waiting }))
        await wait { life.phase == .idle }
        XCTAssertEqual(reads, 5)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(f.converted, 1)
        XCTAssertEqual(f.store.calls, 1)
        XCTAssertEqual(life.lastDeliveryFailure, .resultUnavailable)
        XCTAssertEqual(f.feedback.notice?.title, "変換結果を確認できませんでした")
        XCTAssertFalse(f.feedback.notice?.message.contains("接続") ?? true)
    }

    @MainActor
    func testDelayedConfirmationStopsOnInputSettingsAuthorizationOrTargetChanges() async throws {
        for scenario in 0..<5 {
            let f = try fixture()
            let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
            var reads = 0
            life.observe(.init(observation: DecisionsObservation(text: "sample", latestKey: "e")!,
                isCurrent: { true }, apply: { _ in false },
                verify: { reads += 1; return .cancelled }))
            await wait { life.phase == .verifying }
            if scenario == 0 { life.stop() }
            if scenario == 1 { life.settingsChanged() }
            if scenario == 2 { f.authorized = false }
            if scenario == 3 { var settings = f.store.load(); settings.threshold = 0.9; try f.store.save(settings) }
            await wait { life.phase == .idle }
            try? await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(reads, scenario == 4 ? 1 : 0)
            XCTAssertNil(life.lastError)
            XCTAssertNil(f.feedback.notice)
            XCTAssertEqual(f.store.calls, 1)
            XCTAssertEqual(f.converted, 1)
        }
    }

    @MainActor
    func testNewObservationCancelsOldConfirmationAndUsesOnlyNewestTarget() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        var oldReads = 0
        life.observe(.init(observation: DecisionsObservation(text: "old", latestKey: "d")!,
            isCurrent: { true }, apply: { _ in false }, verify: { oldReads += 1; return .waiting }))
        await wait { life.phase == .verifying }
        life.observe(f.target("new"))
        await wait { life.phase == .idle }
        XCTAssertEqual(oldReads, 0)
        XCTAssertEqual(f.applied, ["結果"])
        XCTAssertEqual(f.store.calls, 2)
        XCTAssertEqual(f.converted, 2)
        XCTAssertNil(f.feedback.notice)
    }

    @MainActor
    func testDebugTextRequiresExplicitMemoryOnlyOptInAndClearsWhenDisabledOrChanged() throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in throw DecisionsError.missingKey }
        let report = AmbientCommitTextReport(source: "dummy source", atOriginal: "", atCaret: "dummy source")
        let result = AmbientResultTextReport(expected: "dummy result", range: NSRange(location: 0, length: 12),
            selection: NSRange(location: 12, length: 0), actual: "old text", caretRange: nil,
            atCaret: nil, stateMatches: true)
        XCTAssertFalse(life.debugTextEnabled)
        life.recordCommitText(report)
        life.recordResultText(result)
        XCTAssertNil(life.lastCommitText)
        XCTAssertNil(life.lastResultText)
        life.setDebugTextEnabled(true)
        life.recordCommitText(report)
        life.recordResultText(result)
        life.stop() // Opening settings preserves the failed attempt for inspection.
        XCTAssertEqual(life.lastCommitText, report)
        XCTAssertEqual(life.lastResultText, result)
        life.setDebugTextEnabled(false)
        XCTAssertNil(life.lastCommitText)
        XCTAssertNil(life.lastResultText)
        life.setDebugTextEnabled(true)
        life.recordCommitText(report)
        life.recordResultText(result)
        life.beginDeliveryAttempt()
        XCTAssertNil(life.lastCommitText)
        XCTAssertNil(life.lastResultText)
        life.recordCommitText(report)
        life.recordResultText(result)
        life.settingsChanged()
        XCTAssertNil(life.lastCommitText)
        XCTAssertNil(life.lastResultText)
        let newLife = f.lifecycle { _, _ in throw DecisionsError.missingKey }
        XCTAssertFalse(newLife.debugTextEnabled)
        XCTAssertNil(newLife.lastCommitText)
        XCTAssertNil(newLife.lastResultText)
    }

    @MainActor
    func testSkippedObservationIsInspectableWithoutSendingAndClearsOnNewObservation() async throws {
        let f = try fixture()
        var prepared = 0
        let life = f.lifecycle { _, _ in prepared += 1; return f.work(score: { _ in 0 }) }
        let ranges = AmbientRangeReport(marked: NSRange(location: 7, length: 3),
                                        selection: NSRange(location: 7, length: 0))
        let read = AmbientSourceReadReport(requestedLength: 3, returnedLength: 0)
        life.skipObservation(.selectionMismatch, ranges: ranges, sourceRead: read)
        life.recordDeliveryFailure(.committedSourceUnavailable)
        life.stop() // Opening settings must preserve the preceding input's reason.
        XCTAssertEqual(life.lastObservationBlock, .selectionMismatch)
        XCTAssertEqual(life.lastObservationRanges, ranges)
        XCTAssertEqual(life.lastSourceReadReport, read)
        XCTAssertEqual(life.lastDeliveryFailure, .committedSourceUnavailable)
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(f.store.calls, 0)
        life.observe(f.target("a"))
        await wait { life.phase == .idle }
        XCTAssertNil(life.lastObservationBlock)
        XCTAssertNil(life.lastObservationRanges)
        XCTAssertNil(life.lastSourceReadReport)
        life.beginDeliveryAttempt()
        XCTAssertNil(life.lastDeliveryFailure)
        XCTAssertEqual(prepared, 1)
        life.skipObservation(.sourceUnavailable)
        life.settingsChanged()
        XCTAssertNil(life.lastObservationBlock)
        XCTAssertNil(life.lastObservationRanges)
    }

    @MainActor
    func testThresholdBoundaryUsesExistingConverterOnlyAtOrAboveThreshold() async throws {
        for score in [0.499, 0.5, 1.0] {
            let f = try fixture()
            let life = f.lifecycle { _, _ in f.work(score: { _ in score }) }
            life.observe(f.target("nihongo "))
            await wait { life.phase == .idle }
            XCTAssertEqual(f.converted, score >= 0.5 ? 1 : 0)
            XCTAssertEqual(f.applied, score >= 0.5 ? ["結果"] : [])
            XCTAssertEqual(f.store.calls, 1)
            XCTAssertEqual(f.currentText, "nihongo ")
            XCTAssertEqual(life.lastDecision?.score, score)
            XCTAssertEqual(life.lastDecision?.threshold, 0.5)
            XCTAssertEqual(life.lastDecision?.accepted, score >= 0.5)
        }
    }

    @MainActor
    func testCaretCueIsTriggeredOnlyForCurrentAcceptedDecisionAndDismissedOnStop() async throws {
        for score in [0.499, 0.5] {
            let f = try fixture()
            var shown = 0
            var dismissed = 0
            let life = AmbientConversionLifecycle(store: f.store, feedback: f.feedback,
                prepare: { _, _ in f.work(score: { _ in score }) }, dismissCue: { dismissed += 1 })
            life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
                isCurrent: { true }, apply: { _ in true }, onAccepted: { shown += 1 }))
            await wait { life.phase == .idle }
            XCTAssertEqual(shown, score >= 0.5 ? 1 : 0)
            let before = dismissed
            life.stop()
            XCTAssertEqual(dismissed, before + 1)
        }
        let f = try fixture()
        let gate = DecisionsScoreGate()
        let life = f.lifecycle { _, _ in f.work(score: { await gate.score($0) }) }
        var shown = 0
        life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
            isCurrent: { f.targetValid }, apply: { _ in true }, onAccepted: { shown += 1 }))
        await wait { await gate.count == 1 }
        f.targetValid = false
        await gate.complete("abc", score: 1)
        await wait { life.phase == .idle }
        XCTAssertEqual(shown, 0)
    }

    @MainActor
    func testAcceptedDecisionsIndicatorLastsUntilConversionFinishesAndSettingsClearHistory() async throws {
        let f = try fixture()
        let gate = DecisionsConversionGate()
        let life = f.lifecycle { observation, _ in
            AmbientWork(score: { _ in 0.8 }, convert: { await gate.convert(observation.text) },
                        remainsAuthorized: { f.authorized })
        }
        life.observe(f.target("abc"))
        await wait { await gate.count == 1 }
        XCTAssertEqual(f.feedback.indicator, .decisionsAccepted)
        XCTAssertEqual(life.phase, .converting)
        XCTAssertEqual(life.lastDecision?.accepted, true)
        await gate.complete("abc")
        await wait { life.phase == .idle }
        XCTAssertEqual(f.feedback.indicator, .idle)
        XCTAssertEqual(life.lastDecision?.score, 0.8)
        life.settingsChanged()
        XCTAssertNil(life.lastDecision)
    }

    @MainActor
    func testEveryQueuedObservationIsSentAndOnlyCurrentScoreCanConvert() async throws {
        let f = try fixture()
        let gate = DecisionsScoreGate()
        let life = f.lifecycle { _, _ in f.work(score: { await gate.score($0) }) }
        life.observe(f.target("a"))
        await wait { await gate.count == 1 }
        life.observe(f.target("ab"))
        life.observe(f.target("abc"))
        XCTAssertEqual(f.store.calls, 1)
        await gate.complete("a", score: 1)
        await wait { await gate.count == 2 }
        var sources = await gate.sources()
        XCTAssertEqual(sources, ["a", "ab"])
        XCTAssertEqual(f.converted, 0)
        await gate.complete("ab", score: 1)
        await wait { await gate.count == 3 }
        sources = await gate.sources()
        XCTAssertEqual(sources, ["a", "ab", "abc"])
        await gate.complete("abc", score: 1)
        await wait { life.phase == .idle }
        XCTAssertEqual(f.applied, ["結果"])
        XCTAssertEqual(f.store.calls, 3)
        XCTAssertEqual(life.lastDecision?.score, 1)
    }

    @MainActor
    func testEditingDuringConversionDiscardsOldResultWithoutQueuingInput() async throws {
        let f = try fixture()
        let gate = DecisionsConversionGate()
        let life = f.lifecycle { observation, _ in
            AmbientWork(score: { _ in 1 }, convert: { await gate.convert(observation.text) },
                        remainsAuthorized: { f.authorized })
        }
        life.observe(f.target("old"))
        await wait { await gate.count == 1 }
        life.observe(f.target("new"))
        XCTAssertEqual(f.currentText, "new")
        await gate.complete("old")
        await wait { await gate.count == 2 }
        XCTAssertTrue(f.applied.isEmpty)
        await gate.complete("new")
        await wait { life.phase == .idle }
        XCTAssertEqual(f.applied, ["new"])
    }

    @MainActor
    func testStopAndLateResponseDoNotWriteOrReportAnError() async throws {
        let f = try fixture()
        let gate = DecisionsScoreGate()
        let life = f.lifecycle { _, _ in f.work(score: { await gate.score($0) }) }
        life.observe(f.target("original"))
        await wait { await gate.count == 1 }
        life.stop()
        await gate.complete("original", score: 1)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(f.applied.isEmpty)
        XCTAssertEqual(f.currentText, "original")
        XCTAssertNil(life.lastError)
        XCTAssertNil(f.feedback.notice)
        XCTAssertFalse(f.feedback.isConverting)
    }

    @MainActor
    func testCancelledSlotIsNotReusedUntilOldTransportFinishes() async throws {
        let f = try fixture()
        let gate = DecisionsScoreGate()
        let life = f.lifecycle { _, _ in f.work(score: { await gate.score($0) }) }
        life.observe(f.target("old"))
        await wait { await gate.count == 1 }
        life.stop()
        life.observe(f.target("new"))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let sources = await gate.sources()
        XCTAssertEqual(sources, ["old"])
        await gate.complete("old", score: 1)
        await wait { await gate.count == 2 }
        await gate.complete("new", score: 0)
        await wait { life.phase == .idle }
        XCTAssertTrue(f.applied.isEmpty)
    }

    @MainActor
    func testMovedCursorOrChangedClientRejectsResult() async throws {
        let f = try fixture()
        let gate = DecisionsScoreGate()
        let life = f.lifecycle { _, _ in f.work(score: { await gate.score($0) }) }
        life.observe(f.target("abc"))
        await wait { await gate.count == 1 }
        f.targetValid = false
        await gate.complete("abc", score: 1)
        await wait { life.phase == .idle }
        XCTAssertEqual(f.converted, 0)
        XCTAssertTrue(f.applied.isEmpty)
    }

    @MainActor
    func testConsentRevocationBeforeResponsePreventsConversion() async throws {
        let f = try fixture()
        let gate = DecisionsScoreGate()
        let life = f.lifecycle { _, _ in f.work(score: { await gate.score($0) }) }
        life.observe(f.target("abc"))
        await wait { await gate.count == 1 }
        var settings = f.store.load()
        settings.consent = false
        try f.store.save(settings)
        await gate.complete("abc", score: 1)
        await wait { life.phase == .idle }
        XCTAssertEqual(f.converted, 0)
        XCTAssertTrue(f.applied.isEmpty)
    }

    @MainActor
    func testAuthorizationChangePreventsSendOrApply() async throws {
        let f = try fixture()
        f.authorized = false
        let life = f.lifecycle { _, _ in f.work(score: { _ in XCTFail("Must not send"); return 1 }) }
        life.observe(f.target("abc"))
        XCTAssertEqual(f.store.calls, 0)
        XCTAssertTrue(f.applied.isEmpty)
    }

    @MainActor
    func testPreparationFailureDoesNotCountPaidRequest() throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in throw DecisionsError.missingKey }
        life.observe(f.target("abc"))
        XCTAssertEqual(f.store.calls, 0)
        XCTAssertNotNil(life.lastError)
        XCTAssertTrue(f.applied.isEmpty)
    }

    @MainActor
    func testFailedAttemptsCountAndCeilingStopsWithoutRetry() async throws {
        let f = try fixture()
        var settings = f.store.load()
        settings.maximumCalls = 2
        try f.store.save(settings)
        let life = f.lifecycle { _, _ in f.work(score: { _ in throw DecisionsError.timedOut }) }
        for text in ["a", "ab"] {
            life.observe(f.target(text))
            await wait { life.phase == .idle }
        }
        life.observe(f.target("abc"))
        XCTAssertEqual(f.store.calls, 2)
        XCTAssertEqual(life.lastError, DecisionsError.requestLimit.message)
        XCTAssertTrue(f.applied.isEmpty)
        life.resetCalls()
        XCTAssertEqual(f.store.calls, 0)
        XCTAssertNil(life.lastError)
    }

    @MainActor
    func testPunctuationDoesNotAddOld500msWaitAndContinuedInputInvalidatesItsScore() async throws {
        let f = try fixture()
        let gate = DecisionsScoreGate()
        let life = f.lifecycle { _, _ in f.work(score: { await gate.score($0) }) }
        life.observe(f.target("a.", key: "."))
        await wait { await gate.count == 1 }
        XCTAssertEqual(f.store.calls, 1)
        life.observe(f.target("ab", key: "BACKSPACE"))
        await gate.complete("a.", score: 1)
        await wait { await gate.count == 2 }
        await gate.complete("ab", score: 0)
        await wait { life.phase == .idle }
        try? await Task.sleep(nanoseconds: 520_000_000)
        let sources = await gate.sources()
        XCTAssertEqual(sources, ["a.", "ab"])
    }

    @MainActor
    func testPunctuationStillNormalizesJapaneseSuffixWithoutPauseMetadata() async throws {
        let f = try fixture()
        var observation: DecisionsObservation?
        let life = f.lifecycle { _, _ in f.work(score: { value in observation = value; return 1 }) }
        life.observe(f.target("nihongo?", key: "?"))
        await wait { f.applied.count == 1 }
        XCTAssertEqual(observation?.latestKey, "?")
        XCTAssertEqual(f.applied, ["結果？"])
    }

    @MainActor
    func testInvalidScoreAndRawConversionErrorUseSafeNotices() async throws {
        for mode in 0..<2 {
            let f = try fixture()
            let life = f.lifecycle { _, _ in
                AmbientWork(score: { _ in mode == 0 ? .nan : 1 },
                            convert: { .failure(.network("private-key private-input private-response")) },
                            remainsAuthorized: { true })
            }
            life.observe(f.target("abc"))
            await wait { life.phase == .idle }
            XCTAssertNotNil(life.lastError)
            XCTAssertFalse(life.lastError?.contains("private") ?? true)
            XCTAssertFalse(f.feedback.notice?.message.contains("private") ?? true)
            XCTAssertTrue(f.applied.isEmpty)
        }
    }

    @MainActor
    func testObservationMismatchRetainsDiagnosticCountsWithoutErrorOrSending() throws {
        let f = try fixture()
        var prepared = 0
        let life = f.lifecycle { _, _ in prepared += 1; throw DecisionsError.missingKey }
        life.skipObservation(.sourceMismatch,
            sourceRead: AmbientSourceReadReport(requestedLength: 101, returnedLength: 100),
            sourceCharacters: 101, sourceUTF16: 101)
        XCTAssertNil(f.feedback.notice)
        XCTAssertEqual(f.feedback.indicator, .idle)
        XCTAssertTrue(life.lastObservationDetails?.contains("要求 101／取得 100") ?? false)
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(f.store.calls, 0)
        for reason in [AmbientObservationBlock.targetChanged, .selectionMismatch, .unsupportedText, .busy, .secureInput] {
            f.feedback.clearNotice()
            life.skipObservation(reason, sourceCharacters: 101, sourceUTF16: 101)
            XCTAssertNil(f.feedback.notice)
        }
    }

    @MainActor
    func testTypingMismatchAtAnyLengthCannotRaiseErrorOrCaretCue() throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in throw DecisionsError.missingKey }
        var cues = 0
        f.feedback.onNotice = { cues += 1 }
        for count in [1, 2, 3, 99, 100, 101, 201] {
            for reason in [AmbientObservationBlock.markedUnavailable, .markedLengthMismatch, .sourceUnavailable, .sourceMismatch] {
                life.skipObservation(reason, sourceCharacters: count, sourceUTF16: count)
                XCTAssertNil(f.feedback.notice)
                XCTAssertEqual(f.feedback.indicator, .idle)
                XCTAssertEqual(life.lastObservationBlock, reason)
                XCTAssertTrue(life.lastObservationDetails?.contains("\(count)文字") ?? false)
            }
        }
        XCTAssertEqual(cues, 0)
        XCTAssertEqual(f.store.calls, 0)
    }

    @MainActor
    func testQuietObservationDoesNotEraseAnActualErrorAndNewObservationClearsSkipDetails() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 0 }) }
        f.feedback.report(.failure(.timedOut))
        life.skipObservation(.sourceMismatch, sourceCharacters: 2, sourceUTF16: 2)
        XCTAssertEqual(f.feedback.notice, .failure(.timedOut))
        f.feedback.clearNotice()
        life.observe(f.target("abc"))
        XCTAssertNil(life.lastObservationBlock)
        XCTAssertNil(life.lastObservationDetails)
        await wait { life.phase == .idle }
        XCTAssertNil(f.feedback.notice)
        life.skipObservation(.markedLengthMismatch, sourceCharacters: 2, sourceUTF16: 2)
        life.settingsChanged()
        XCTAssertNil(life.lastObservationDetails)
    }

    @MainActor
    func testActualDeliveryFailuresKeepSpecificStageWhileSessionChangesAreSilent() async throws {
        for failure in [AmbientDeliveryFailure.committedSourceUnavailable, .committedSourceMismatch,
                        .committedTargetMismatch, .replacementRejected, .targetChangedBeforeCommit, .requestChangedDuringCommit] {
            let f = try fixture()
            let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
            let source = String(repeating: "a", count: 101)
            life.observe(.init(observation: DecisionsObservation(text: source, latestKey: "a")!,
                isCurrent: { true }, apply: { _ in life.recordDeliveryFailure(failure); return false }))
            await wait { life.phase == .idle }
            if failure.isCancellation { XCTAssertNil(f.feedback.notice) }
            else {
                XCTAssertEqual(f.feedback.notice?.message, failure.rawValue)
                XCTAssertNotNil(f.feedback.notice?.stage)
                XCTAssertTrue(f.feedback.notice?.details?.contains("101文字") ?? false)
                XCTAssertFalse(f.feedback.notice?.message.contains("接続") ?? true)
            }
            XCTAssertEqual(f.store.calls, 1)
            XCTAssertEqual(f.converted, 1)
        }
    }

    @MainActor
    func testAutomaticReadbackTimeoutReportsActualReadLengthWithoutAnotherRequest() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        let source = String(repeating: "a", count: 201)
        life.observe(.init(observation: DecisionsObservation(text: source, latestKey: "a")!,
            isCurrent: { true }, apply: { _ in false }, verify: {
                life.recordResultReadback(.lengthMismatch(100), expectedUTF16: 110)
                return .waiting
            }))
        await wait { life.phase == .idle }
        XCTAssertEqual(f.feedback.notice, .resultConfirmation(.lengthMismatch(100),
            sourceCharacters: 201, sourceUTF16: 201, expectedUTF16: 110))
        XCTAssertEqual(f.store.calls, 1)
        XCTAssertEqual(f.converted, 1)
    }

    @MainActor
    func testFailedDeliveryCannotBeReportedAsSuccess() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        f.currentText = "abc"
        life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
                           isCurrent: { true }, apply: { _ in false }))
        await wait { life.phase == .idle }
        XCTAssertEqual(f.feedback.notice?.stage, ConversionDeliveryStage.replacement.rawValue)
        XCTAssertEqual(f.feedback.notice?.message, ReplacementValidationFailure.trackingUnavailable.message)
        XCTAssertNotNil(life.lastError)
    }

    @MainActor
    func testCommittedSourceRetryUsesOneRequestAndStopsAfterMatchingRead() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        var attempts = 0
        var cleaned = false
        life.observe(.init(observation: DecisionsObservation(text: "abcdefghijklmnopqr", latestKey: "r")!,
            isCurrent: { true }, apply: { _ in false }, sourceContinuation: {
                .init(poll: { _ in attempts += 1; return attempts == 3 ? .applied : .waiting },
                    cancel: { cleaned = true })
            }))
        await wait { life.phase == .verifyingSource }
        XCTAssertTrue(f.feedback.isConverting)
        await wait { life.phase == .idle }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(f.store.calls, 1); XCTAssertEqual(f.converted, 1)
        XCTAssertTrue(cleaned); XCTAssertNil(f.feedback.notice)
    }

    @MainActor
    func testCommittedSourceTimeoutStopsAtFiveReadsAndKeepsSpecificFailure() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        var attempts = 0
        var cleaned = false
        life.observe(.init(observation: DecisionsObservation(text: "abcdefghijklmnopqr", latestKey: "r")!,
            isCurrent: { true }, apply: { _ in false }, sourceContinuation: {
                .init(poll: { _ in attempts += 1; return .waiting }, cancel: { cleaned = true })
            }))
        await wait { life.phase == .idle }
        XCTAssertTrue((1...5).contains(attempts)); XCTAssertTrue(cleaned)
        XCTAssertEqual(life.lastDeliveryFailure, .committedSourceUnavailable)
        XCTAssertEqual(f.feedback.notice?.stage, ConversionDeliveryStage.committedSource.rawValue)
        XCTAssertEqual(f.feedback.notice?.message, AmbientDeliveryFailure.committedSourceUnavailable.rawValue)
        XCTAssertTrue(f.feedback.notice?.details?.contains("18文字") ?? false)
        XCTAssertEqual(f.store.calls, 1); XCTAssertEqual(f.converted, 1)
    }

    @MainActor
    func testSourceMismatchAndChangedTargetDoNotConsumeRemainingRetries() async throws {
        for mismatch in [false, true] {
            let f = try fixture()
            let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
            var attempts = 0
            var cleaned = false
            life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
                isCurrent: { true }, apply: { _ in false }, sourceContinuation: {
                    .init(poll: { _ in attempts += 1; return mismatch ? .failed(.committedSourceMismatch) : .cancelled },
                        cancel: { cleaned = true })
                }))
            await wait { life.phase == .idle }
            XCTAssertEqual(attempts, 1); XCTAssertTrue(cleaned)
            if mismatch { XCTAssertEqual(life.lastDeliveryFailure, .committedSourceMismatch) }
            else { XCTAssertNil(f.feedback.notice) }
            XCTAssertEqual(f.store.calls, 1); XCTAssertEqual(f.converted, 1)
        }
    }

    @MainActor
    func testSourceWaitStopSettingsAndAuthorizationChangesCancelBeforePolling() async throws {
        for scenario in 0..<3 {
            let f = try fixture()
            let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
            var attempts = 0
            var cleaned = false
            life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
                isCurrent: { true }, apply: { _ in false }, sourceContinuation: {
                    .init(poll: { _ in attempts += 1; return .applied }, cancel: { cleaned = true })
                }))
            await wait { life.phase == .verifyingSource }
            switch scenario {
            case 0: life.stop()
            case 1: var settings = f.store.load(); settings.consent = false; try f.store.save(settings)
            default: f.authorized = false
            }
            await wait { cleaned }
            XCTAssertEqual(attempts, 0)
            XCTAssertNil(f.feedback.notice)
            XCTAssertEqual(f.store.calls, 1); XCTAssertEqual(f.converted, 1)
        }
    }

    @MainActor
    func testSourceReadThenResultReadRemainInOnePaidPipeline() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        var sourceReads = 0
        var resultReads = 0
        life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
            isCurrent: { true }, apply: { _ in false }, verify: {
                resultReads += 1; return resultReads == 2 ? .confirmed : .waiting
            }, sourceContinuation: {
                .init(poll: { _ in sourceReads += 1; return sourceReads == 2 ? .verifyingResult : .waiting },
                    cancel: {})
            }))
        await wait { life.phase == .verifying }
        await wait { life.phase == .idle }
        XCTAssertEqual(sourceReads, 2); XCTAssertEqual(resultReads, 2)
        XCTAssertEqual(f.store.calls, 1); XCTAssertEqual(f.converted, 1)
        XCTAssertNil(f.feedback.notice)
    }

    @MainActor
    func testSourceTimeoutDoesNotRequireClearingErrorToConvertNextInput() async throws {
        let f = try fixture()
        let life = f.lifecycle { _, _ in f.work(score: { _ in 1 }) }
        life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
            isCurrent: { true }, apply: { _ in false }, sourceContinuation: {
                .init(poll: { _ in .waiting }, cancel: {})
            }))
        await wait { life.phase == .idle }
        let oldNotice = f.feedback.notice
        XCTAssertNotNil(oldNotice)
        life.observe(f.target("next"))
        await wait { life.phase == .idle }
        XCTAssertEqual(f.applied, ["結果"])
        XCTAssertEqual(f.converted, 2); XCTAssertEqual(f.store.calls, 2)
        XCTAssertNil(life.lastError)
        // Existing notices remain acknowledgeable UI only; never a conversion gate.
        XCTAssertEqual(f.feedback.notice, oldNotice)
    }

    @MainActor
    func testOverdueSourceReadTaskCannotApplyAfterDeadline() async throws {
        let f = try fixture()
        var instant: TimeInterval = 0
        let life = AmbientConversionLifecycle(store: f.store, feedback: f.feedback,
            prepare: { _, _ in f.work(score: { _ in 1 }) }, now: { instant })
        var attempts = 0
        var cleaned = false
        life.observe(.init(observation: DecisionsObservation(text: "abc", latestKey: "c")!,
            isCurrent: { true }, apply: { _ in false }, sourceContinuation: {
                .init(poll: { _ in attempts += 1; return .applied }, cancel: { cleaned = true })
            }))
        await wait { life.phase == .verifyingSource }
        instant = 0.5
        await wait { life.phase == .idle }
        XCTAssertEqual(attempts, 0); XCTAssertTrue(cleaned)
        XCTAssertEqual(life.lastDeliveryFailure, .committedSourceUnavailable)
        XCTAssertEqual(f.store.calls, 1); XCTAssertEqual(f.converted, 1)
    }
}

@MainActor
private final class AmbientFixture {
    let domain: String
    let defaults: UserDefaults
    let store: DecisionsSettingsStore
    let feedback = ConversionFeedback()
    var currentText = ""
    var targetValid = true
    var authorized = true
    var converted = 0
    var applied: [String] = []
    init(enabled: Bool) throws {
        domain = "org.sumibi.tests.ambient.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        store = DecisionsSettingsStore(defaults: defaults)
        var settings = DecisionsSettings()
        settings.enabled = enabled
        settings.consent = enabled
        settings.batchWindowMilliseconds = 0 // Single-request regression cases; fixed windows tested separately.
        try store.save(settings)
    }
    func lifecycle(_ prepare: @escaping (DecisionsObservation, DecisionsSettings) throws -> AmbientWork) -> AmbientConversionLifecycle {
        AmbientConversionLifecycle(store: store, feedback: feedback, prepare: prepare)
    }
    func work(score: @escaping (DecisionsObservation) async throws -> Double) -> AmbientWork {
        AmbientWork(score: score, convert: { self.converted += 1; return .success(ConversionResult(candidates: ["結果"])) },
                    remainsAuthorized: { self.authorized })
    }
    func target(_ text: String, key: String? = nil) -> AmbientConversionLifecycle.Target {
        currentText = text
        return .init(observation: DecisionsObservation(text: text, latestKey: key ?? String(text.last!))!,
                     isCurrent: { self.targetValid && self.currentText == text },
                     apply: { self.applied.append($0.candidates.first!); return true })
    }
    deinit { defaults.removePersistentDomain(forName: domain) }
}

private actor DecisionsScoreGate {
    private var observed: [DecisionsObservation] = []
    private var pending: [String: CheckedContinuation<Double, Never>] = [:]
    var count: Int { observed.count }
    func sources() -> [String] { observed.map(\.text) }
    func score(_ observation: DecisionsObservation) async -> Double {
        observed.append(observation)
        return await withCheckedContinuation { pending[observation.text] = $0 }
    }
    func complete(_ source: String, score: Double) { pending.removeValue(forKey: source)?.resume(returning: score) }
}

private actor DecisionsConversionGate {
    private var pending: [String: CheckedContinuation<Result<ConversionResult, ConversionError>, Never>] = [:]
    var count = 0
    func convert(_ source: String) async -> Result<ConversionResult, ConversionError> {
        count += 1
        return await withCheckedContinuation { pending[source] = $0 }
    }
    func complete(_ source: String) {
        pending.removeValue(forKey: source)?.resume(returning: .success(ConversionResult(candidates: [source])))
    }
}
