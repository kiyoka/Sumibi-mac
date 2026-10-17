import XCTest
import SumibiCore
@testable import SumibiIME

@MainActor
final class DecisionsBatchLifecycleTests: XCTestCase {
    private func wait(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Mock operation did not complete")
    }

    func testFixedWindowRetainsEveryPrefixButOnlyCurrentAnswerCanConvert() async throws {
        let f = try BatchFixture()
        let life = f.lifecycle()
        for text in ["n", "ni", "nihongo"] { life.observe(f.target(text)) }
        XCTAssertEqual(life.phase, .collecting); XCTAssertEqual(f.store.calls, 0)
        await wait { await f.gate.count == 1 }
        let batches = await f.gate.batches
        XCTAssertEqual(batches, [["n", "ni", "nihongo"]])
        XCTAssertEqual(f.store.calls, 1)
        await f.gate.complete([.probability(1), .probability(1), .probability(0.499)])
        await wait { life.phase == .idle }
        XCTAssertEqual(life.lastDecision?.score, 0.499)
        XCTAssertEqual(f.converted, 0); XCTAssertTrue(f.applied.isEmpty)
    }

    func testCurrentThresholdAnswerShowsCueAndConvertsOnlyOnce() async throws {
        let f = try BatchFixture()
        let life = f.lifecycle()
        for text in ["n", "ni", "nihongo"] { life.observe(f.target(text)) }
        await wait { await f.gate.count == 1 }
        await f.gate.complete([.probability(0.1), .probability(0.2), .probability(0.5)])
        await wait { life.phase == .idle }
        XCTAssertEqual(f.converted, 1); XCTAssertEqual(f.accepted, 1)
        XCTAssertEqual(f.applied, ["nihongo"]); XCTAssertEqual(f.store.calls, 1)
    }

    func testInputChecksExpiredDeadlineBeforeOverdueTimerAndDoesNotExtendWindow() async throws {
        let f = try BatchFixture()
        var instant: TimeInterval = 0
        let life = f.lifecycle(now: { instant })
        life.observe(f.target("a"))
        instant = 0.199; life.observe(f.target("ab"))
        XCTAssertEqual(f.store.calls, 0)
        instant = 0.2; life.observe(f.target("abc"))
        await wait { await f.gate.count == 1 }
        var batches = await f.gate.batches
        XCTAssertEqual(batches, [["a", "ab"]])
        await f.gate.complete([.probability(1), .probability(1)])
        await wait { await f.gate.count == 2 }
        batches = await f.gate.batches
        XCTAssertEqual(batches, [["a", "ab"], ["abc"]])
        XCTAssertTrue(f.applied.isEmpty)
        await f.gate.complete([.probability(0)])
        await wait { life.phase == .idle }
        XCTAssertEqual(f.store.calls, 2)
    }

    func testSlowTransportKeepsSubsequentWindowsWithoutOverlappingRequests() async throws {
        let f = try BatchFixture()
        let life = f.lifecycle()
        life.observe(f.target("old"))
        await wait { await f.gate.count == 1 }
        life.observe(f.target("new")); life.observe(f.target("newer"))
        try? await Task.sleep(nanoseconds: 250_000_000)
        let before = await f.gate.count
        XCTAssertEqual(before, 1); XCTAssertEqual(f.store.calls, 1)
        await f.gate.complete([.probability(1)])
        await wait { await f.gate.count == 2 }
        let batches = await f.gate.batches
        XCTAssertEqual(batches, [["old"], ["new", "newer"]])
        XCTAssertEqual(f.converted, 0)
        await f.gate.complete([.probability(1), .probability(1)])
        await wait { life.phase == .idle }
        XCTAssertEqual(f.applied, ["newer"])
    }

    func testLargeWindowSplitsAt32StatesWithoutDroppingInput() async throws {
        let f = try BatchFixture(window: 200)
        let life = f.lifecycle(now: { 0 })
        let sources = (1...65).map { "input\($0)" }
        for source in sources { life.observe(f.target(source)) }
        for (index, count) in [32, 32, 1].enumerated() {
            await wait { await f.gate.count == index + 1 }
            await f.gate.complete(Array(repeating: .probability(0), count: count))
        }
        await wait { life.phase == .idle }
        let batches = await f.gate.batches
        XCTAssertEqual(batches.map(\.count), [32, 32, 1])
        XCTAssertEqual(batches.flatMap { $0 }, sources)
        XCTAssertEqual(f.store.calls, 3); XCTAssertTrue(f.applied.isEmpty)
    }

    func testStopClearsUnsentWindowsAndLateResponseCannotConvert() async throws {
        let f = try BatchFixture()
        let life = f.lifecycle()
        life.observe(f.target("old"))
        await wait { await f.gate.count == 1 }
        life.observe(f.target("new")); life.stop()
        await f.gate.complete([.probability(1)])
        try? await Task.sleep(nanoseconds: 250_000_000)
        let count = await f.gate.count
        XCTAssertEqual(count, 1); XCTAssertEqual(f.store.calls, 1)
        XCTAssertEqual(f.converted, 0); XCTAssertNil(f.feedback.notice)
    }

    func testConsentOrAuthorizationChangePreventsBatchResultApplication() async throws {
        for revokeConsent in [false, true] {
            let f = try BatchFixture()
            let life = f.lifecycle()
            life.observe(f.target("nihongo"))
            await wait { await f.gate.count == 1 }
            if revokeConsent { var settings = f.store.load(); settings.consent = false; try f.store.save(settings) }
            else { f.authorized = false }
            await f.gate.complete([.probability(1)])
            await wait { life.phase == .idle }
            XCTAssertEqual(f.converted, 0); XCTAssertTrue(f.applied.isEmpty)
            XCTAssertNil(f.feedback.notice)
        }
    }

    func testRefusedOldPrefixDoesNotBlockValidCurrentInput() async throws {
        let f = try BatchFixture()
        let life = f.lifecycle()
        life.observe(f.target("n")); life.observe(f.target("nihongo"))
        await wait { await f.gate.count == 1 }
        await f.gate.complete([.refused, .probability(1)])
        await wait { life.phase == .idle }
        XCTAssertEqual(f.applied, ["nihongo"]); XCTAssertNil(f.feedback.notice)
    }

    func testCurrentRefusalHasSafeErrorAndNoConversion() async throws {
        let f = try BatchFixture()
        let life = f.lifecycle()
        life.observe(f.target("nihongo"))
        await wait { await f.gate.count == 1 }
        await f.gate.complete([.refused])
        await wait { life.phase == .idle }
        XCTAssertEqual(f.feedback.notice?.message, DecisionsError.refused.message)
        XCTAssertEqual(f.converted, 0); XCTAssertEqual(f.store.calls, 1)
    }

    func testQueuedCeilingAndMemoryBoundStopWithoutSendingOrChangingInput() throws {
        for ceiling in [true, false] {
            let f = try BatchFixture(window: 1_000)
            var settings = f.store.load(); settings.maximumCalls = ceiling ? 1 : 10_000; try f.store.save(settings)
            let life = f.lifecycle(now: { 0 })
            let count = ceiling ? 33 : 257
            for index in 1...count { life.observe(f.target("input\(index)")) }
            XCTAssertEqual(f.store.calls, 0); XCTAssertTrue(f.applied.isEmpty)
            XCTAssertEqual(f.currentText, "input\(count)")
            if ceiling { XCTAssertEqual(life.lastError, DecisionsError.requestLimit.message) }
            else { XCTAssertEqual(life.lastObservationBlock, .queueFull); XCTAssertNil(f.feedback.notice) }
            life.stop()
        }
    }
}

@MainActor
private final class BatchFixture {
    let domain = "org.sumibi.tests.decisions-batch.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: DecisionsSettingsStore
    let feedback = ConversionFeedback()
    let gate = DecisionsBatchGate()
    var currentText = ""
    var authorized = true
    var converted = 0
    var accepted = 0
    var applied: [String] = []
    init(window: Int = 200) throws {
        defaults = UserDefaults(suiteName: domain)!
        store = DecisionsSettingsStore(defaults: defaults)
        var settings = DecisionsSettings()
        settings.enabled = true; settings.consent = true; settings.batchWindowMilliseconds = window
        try store.save(settings)
    }
    func lifecycle(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> AmbientConversionLifecycle {
        AmbientConversionLifecycle(store: store, feedback: feedback, prepare: { observation, _ in
            AmbientWork(score: { _ in XCTFail("Must use batch transport"); return 0 },
                convert: { self.converted += 1; return .success(.init(candidates: [observation.text])) },
                remainsAuthorized: { self.authorized }, scoreBatch: { await self.gate.scores($0) })
        }, now: now)
    }
    func target(_ source: String) -> AmbientConversionLifecycle.Target {
        currentText = source
        return .init(observation: DecisionsObservation(text: source, latestKey: "o")!,
            isCurrent: { self.currentText == source },
            apply: { self.applied.append($0.candidates[0]); return true },
            onAccepted: { self.accepted += 1 })
    }
    deinit { defaults.removePersistentDomain(forName: domain) }
}

private actor DecisionsBatchGate {
    var batches: [[String]] = []
    var count: Int { batches.count }
    private var pending: CheckedContinuation<[DecisionsAnswer], Never>?
    func scores(_ observations: [DecisionsObservation]) async -> [DecisionsAnswer] {
        batches.append(observations.map(\.text))
        return await withCheckedContinuation { pending = $0 }
    }
    func complete(_ answers: [DecisionsAnswer]) { let continuation = pending; pending = nil; continuation?.resume(returning: answers) }
}
