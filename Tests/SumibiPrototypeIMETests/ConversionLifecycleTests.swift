import XCTest
import SumibiPrototypeCore
@testable import SumibiPrototypeIME

final class ConversionLifecycleTests: XCTestCase {
    @MainActor
    func testReadyOutcomeIsConsumedExactlyOnceForMatchingID() async {
        let session = firstRequest("abc")
        let lifecycle = ConversionLifecycle(session: session) { _ in .success(ConversionResult(candidates: ["結果"])) }
        let ready = expectation(description: "ready")
        let id = session.pending!.id
        lifecycle.start(id: id, request: ConversionRequest(source: "abc")) { received in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(received, id)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertNotNil(lifecycle.readyAt)
        XCTAssertNil(lifecycle.takeOutcome(id: id + 1))
        XCTAssertEqual(lifecycle.takeOutcome(id: id), .first("結果"))
        XCTAssertNil(lifecycle.takeOutcome(id: id))
        XCTAssertNil(lifecycle.readyAt)
    }

    @MainActor
    func testLateCancelledResponseCannotOverwriteANewRequest() async {
        let session = firstRequest("old")
        let startedOld = expectation(description: "old started")
        let startedNew = expectation(description: "new started")
        let work = ControlledConversion(started: ["old": startedOld, "new": startedNew])
        let lifecycle = ConversionLifecycle(session: session) { await work.convert($0) }
        let oldReady = expectation(description: "old response ignored")
        oldReady.isInverted = true
        lifecycle.start(id: session.pending!.id, request: ConversionRequest(source: "old")) { _ in oldReady.fulfill() }
        await fulfillment(of: [startedOld], timeout: 2)
        _ = session.cancelForTargetChange()
        lifecycle.cancel()
        _ = session.receive(.text("new"))
        _ = session.receive(.convert)
        let newID = session.pending!.id
        let newReady = expectation(description: "new ready")
        lifecycle.start(id: newID, request: ConversionRequest(source: "new")) { _ in newReady.fulfill() }
        await fulfillment(of: [startedNew], timeout: 2)
        await work.complete("new", result: .success(ConversionResult(candidates: ["新結果"])))
        await fulfillment(of: [newReady], timeout: 2)
        await work.complete("old", result: .success(ConversionResult(candidates: ["旧結果"])))
        await fulfillment(of: [oldReady], timeout: 0.05)
        XCTAssertEqual(lifecycle.takeOutcome(id: newID), .first("新結果"))
    }

    @MainActor
    func testEscapeAfterResponseIsReadyRescuesQueuedTextAndDropsOutcome() async {
        let session = firstRequest("abc")
        _ = session.receive(.text("queued"))
        _ = session.receive(.enter)
        let lifecycle = ConversionLifecycle(session: session) { _ in .success(ConversionResult(candidates: ["結果"])) }
        let id = session.pending!.id
        let ready = expectation(description: "ready")
        lifecycle.start(id: id, request: ConversionRequest(source: "abc")) { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(session.cancelComposition(originalCommitted: true), [.rescueText("queued")])
        lifecycle.cancel()
        XCTAssertNil(lifecycle.takeOutcome(id: id))
        XCTAssertNil(lifecycle.readyAt)
        XCTAssertEqual(session.completeFirst(id: id, result: "結果"), [])
    }

    @MainActor
    func testCancellationStopsScheduledDelivery() async {
        let session = firstRequest("abc")
        let lifecycle = ConversionLifecycle(session: session) { _ in .failure(.offline) }
        let ready = expectation(description: "ready")
        let id = session.pending!.id
        lifecycle.start(id: id, request: ConversionRequest(source: "abc")) { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        let delivery = expectation(description: "cancelled timer does not deliver")
        delivery.isInverted = true
        lifecycle.scheduleFinish(id: id, delay: 0.01, retry: true) { _ in delivery.fulfill() }
        lifecycle.cancel()
        await fulfillment(of: [delivery], timeout: 0.05)
    }

    @MainActor
    func testTargetChangeWithoutExplicitLifecycleCancelStillDropsResponse() async {
        let session = firstRequest("abc")
        let started = expectation(description: "started")
        let work = ControlledConversion(started: ["abc": started])
        let lifecycle = ConversionLifecycle(session: session) { await work.convert($0) }
        let ready = expectation(description: "stale ready is not called")
        ready.isInverted = true
        lifecycle.start(id: session.pending!.id, request: ConversionRequest(source: "abc")) { _ in ready.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        _ = session.cancelForTargetChange()
        await work.complete("abc", result: .success(ConversionResult(candidates: ["結果"])))
        await fulfillment(of: [ready], timeout: 0.05)
        XCTAssertNil(lifecycle.readyAt)
        lifecycle.cancel()
    }

    @MainActor
    func testSelectionFailurePreservesSourceAndDrainsQueuedText() async {
        let session = InputSession()
        _ = session.convertSelection("selected source")
        _ = session.receive(.text("queued"))
        let id = session.pending!.id
        let lifecycle = ConversionLifecycle(session: session) { _ in .failure(.timedOut) }
        let ready = expectation(description: "ready")
        lifecycle.start(id: id, request: ConversionRequest(source: "selected source")) { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(lifecycle.takeOutcome(id: id), .failure(.timedOut))
        XCTAssertEqual(session.completeSelection(id: id, result: nil), [.marked("queued")])
        XCTAssertNil(session.previous)
    }

    func testUnavailableClientRetryLimitMatchesExistingBehavior() {
        let lifecycle = ConversionLifecycle(session: InputSession())
        for _ in 1...240 { XCTAssertTrue(lifecycle.recordUnavailableClient()) }
        XCTAssertFalse(lifecycle.recordUnavailableClient())
        lifecycle.cancel()
        XCTAssertEqual(lifecycle.retryCount, 0)
    }

    private func firstRequest(_ source: String) -> InputSession {
        let session = InputSession()
        _ = session.receive(.text(source))
        _ = session.receive(.convert)
        return session
    }
}

private actor ControlledConversion {
    private let started: [String: XCTestExpectation]
    private var pending: [String: CheckedContinuation<Result<ConversionResult, ConversionError>, Never>] = [:]
    init(started: [String: XCTestExpectation]) { self.started = started }
    func convert(_ request: ConversionRequest) async -> Result<ConversionResult, ConversionError> {
        await withCheckedContinuation { continuation in
            pending[request.source] = continuation
            started[request.source]?.fulfill()
        }
    }
    func complete(_ source: String, result: Result<ConversionResult, ConversionError>) {
        pending.removeValue(forKey: source)?.resume(returning: result)
    }
}
