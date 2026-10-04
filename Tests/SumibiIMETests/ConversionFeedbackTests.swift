import XCTest
import SumibiCore
@testable import SumibiIME

final class ConversionFeedbackTests: XCTestCase {
    func testIdleWaitingAndFinishIndicatorsDoNotRequireAcknowledgement() {
        let feedback = ConversionFeedback()
        XCTAssertEqual(feedback.indicator, .idle)
        feedback.begin()
        XCTAssertEqual(feedback.indicator, .converting)
        XCTAssertTrue(feedback.accessibilityLabel.contains("変換中"))
        feedback.finish()
        XCTAssertEqual(feedback.indicator, .idle)
    }

    func testLatestErrorStaysUntilExplicitClearEvenAfterSuccessfulConversion() {
        let feedback = ConversionFeedback()
        let first = ConversionNotice.failure(.apiKeyMissing)
        let latest = ConversionNotice.failure(.timedOut)
        feedback.report(first)
        feedback.begin()
        XCTAssertEqual(feedback.indicator, .error)
        XCTAssertTrue(feedback.accessibilityLabel.contains("変換中"))
        feedback.report(latest)
        feedback.finish()
        XCTAssertEqual(feedback.notice, latest)
        XCTAssertEqual(feedback.indicator, .error)
        feedback.clearNotice()
        XCTAssertNil(feedback.notice)
        XCTAssertEqual(feedback.indicator, .idle)
    }

    func testClearingErrorDuringConversionDoesNotStopInputOrTheRequest() {
        let runtime = InputRuntime()
        _ = runtime.state.receive(.text("original"))
        _ = runtime.state.receive(.convert)
        _ = runtime.state.receive(.text("queued"))
        let request = runtime.state.pending
        runtime.feedback.begin()
        runtime.feedback.report(.failure(.network("secret")))
        runtime.feedback.clearNotice()
        XCTAssertEqual(runtime.state.pending, request)
        XCTAssertEqual(runtime.state.marked, "original")
        XCTAssertEqual(runtime.state.completeFirst(id: request!.id, result: "結果"), [.commit("結果"), .marked("queued")])
        XCTAssertTrue(runtime.feedback.isConverting)
        XCTAssertEqual(runtime.feedback.indicator, .converting)
    }

    func testEveryFailureHasSafeCauseAndRemedyWithoutRawNetworkDetails() {
        let errors: [ConversionError] = [.apiKeyMissing, .consentMissing, .overLimit(count: 1_001, limit: 1_000),
            .invalidEndpoint, .invalidCredentials, .rateLimited, .serverError(statusCode: 503),
            .httpError(statusCode: 400), .emptyResponse, .timedOut, .offline,
            .network("fake-api-key original-input surrounding-text https://private.invalid")]
        for error in errors {
            let notice = ConversionNotice.failure(error)
            XCTAssertFalse(notice.title.isEmpty)
            XCTAssertFalse(notice.message.isEmpty)
            XCTAssertFalse(notice.advice.isEmpty)
            let text = [notice.title, notice.message, notice.advice].joined()
            for secret in ["fake-api-key", "original-input", "surrounding-text", "private.invalid"] {
                XCTAssertFalse(text.contains(secret))
            }
        }
    }

    func testFourRequiredFailureKindsAreDistinct() {
        let errors: [ConversionError] = [.network("fake"), .timedOut, .overLimit(count: 1_001, limit: 1_000), .apiKeyMissing]
        XCTAssertEqual(Set(errors.map { ConversionNotice.failure($0).title }).count, 4)
    }

    func testBlockedLongInputReportsErrorWithoutStartingConversionOrLosingOriginal() {
        let runtime = InputRuntime()
        let input = FeedbackInputClient()
        var started = false
        let applier = InputEffectApplier(runtime: runtime, startConversion: { _, _ in started = true },
                                        pokeClient: { _ in }, selectCandidate: { _ in })
        _ = applier.apply(runtime.state.receive(.text(String(repeating: "a", count: 1_001))), to: input)
        _ = applier.apply(runtime.state.receive(.convert), to: input)
        XCTAssertFalse(started)
        XCTAssertNil(runtime.state.pending)
        XCTAssertEqual(runtime.state.marked.count, 1_001)
        XCTAssertEqual(input.text.count, 1_001)
        XCTAssertEqual(runtime.feedback.notice, .failure(.overLimit(count: 1_001, limit: 1_000)))
    }

    @MainActor
    func testFailureIsReportedWhenReadyWithoutWaitingForAClientOrMenuClick() async {
        let session = InputSession()
        _ = session.receive(.text("original"))
        _ = session.receive(.convert)
        let id = session.pending!.id
        let feedback = ConversionFeedback()
        let lifecycle = ConversionLifecycle(session: session, feedback: feedback) { _ in .failure(.timedOut) }
        let ready = expectation(description: "ready")
        lifecycle.start(id: id, request: ConversionRequest(source: "original")) { _ in ready.fulfill() }
        XCTAssertTrue(feedback.isConverting)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(feedback.notice, .failure(.timedOut))
        XCTAssertTrue(feedback.isConverting) // Delivery is still pending.
        XCTAssertEqual(session.marked, "original")
        XCTAssertEqual(lifecycle.takeOutcome(id: id), .failure(.timedOut))
        XCTAssertFalse(feedback.isConverting)
        XCTAssertEqual(feedback.indicator, .error)
    }

    @MainActor
    func testCancelledLateFailureCannotCreateAnErrorNotice() async {
        let session = InputSession()
        _ = session.receive(.text("original"))
        _ = session.receive(.convert)
        let feedback = ConversionFeedback()
        let started = expectation(description: "started")
        var continuation: CheckedContinuation<Result<ConversionResult, ConversionError>, Never>?
        let lifecycle = ConversionLifecycle(session: session, feedback: feedback) { _ in
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let ready = expectation(description: "must not deliver cancelled error")
        ready.isInverted = true
        lifecycle.start(id: session.pending!.id, request: ConversionRequest(source: "original")) { _ in ready.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        _ = session.cancelForTargetChange()
        lifecycle.cancel()
        continuation?.resume(returning: .failure(.network("secret")))
        await fulfillment(of: [ready], timeout: 0.05)
        XCTAssertNil(feedback.notice)
        XCTAssertEqual(feedback.indicator, .idle)
    }

    func testFeedbackChangeCallbackOnlyObservesPresentationState() {
        let feedback = ConversionFeedback()
        var indicators: [ConversionFeedback.Indicator] = []
        feedback.onChange = { [weak feedback] in if let feedback { indicators.append(feedback.indicator) } }
        feedback.begin()
        feedback.report(.selectionUnreadable)
        feedback.finish()
        feedback.clearNotice()
        XCTAssertEqual(indicators, [.converting, .error, .error, .idle])
    }
}

private final class FeedbackInputClient: InputClient {
    var text = ""
    func selectedRange() -> NSRange { NSRange(location: text.utf16.count, length: 0) }
    func markedRange() -> NSRange { NSRange(location: 0, length: text.utf16.count) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { nil }
    func insertText(_ text: Any, replacementRange: NSRange) { self.text = text as? String ?? "" }
    func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange) {
        self.text = (text as? NSAttributedString)?.string ?? text as? String ?? ""
    }
    func lineRect(at index: Int) -> NSRect { .zero }
}
