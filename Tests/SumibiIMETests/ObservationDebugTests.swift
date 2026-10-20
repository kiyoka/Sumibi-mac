import XCTest
import SumibiCore
@testable import SumibiIME

final class ObservationDebugTests: XCTestCase {
    func testCaptureReportsSameLengthMismatchUsingTheExistingRead() {
        let input = ObservationReadClient(actual: "different text", count: 14)
        var report: AmbientObservationTextReport?
        let result = AmbientInputSnapshot.capture(source: "original text!", input: input,
            onSourceText: { report = $0 })
        guard case .failure(.sourceMismatch) = result else { return XCTFail("Must still reject mismatching text") }
        XCTAssertEqual(report?.source, "original text!")
        XCTAssertEqual(report?.actual, "different text")
        XCTAssertEqual(report?.stage, .capture)
        XCTAssertEqual(report?.ranges.marked, input.markedRange())
        XCTAssertEqual(report?.ranges.selection, input.selectedRange())
        XCTAssertEqual(input.reads, [NSRange(location: 0, length: 14)])
        let withoutDebug = AmbientInputSnapshot.capture(source: "original text!", input: input)
        guard case .failure(.sourceMismatch) = withoutDebug else { return XCTFail("Opt-in must not change validation") }
        XCTAssertEqual(input.reads.count, 2)
    }

    func testValidationReportsTheRecheckStageWithoutAdditionalReads() throws {
        let input = ObservationReadClient(actual: "original text!", count: 14)
        let snapshot = try XCTUnwrap(AmbientInputSnapshot(source: "original text!", input: input))
        input.actual = "different text"
        var report: AmbientObservationTextReport?
        XCTAssertEqual(snapshot.validationFailure(in: input, onSourceText: { report = $0 }), .sourceMismatch)
        XCTAssertEqual(report?.stage, .validation)
        XCTAssertEqual(report?.source, "original text!")
        XCTAssertEqual(report?.actual, "different text")
        XCTAssertEqual(input.reads.count, 2) // Initial capture + existing validation read only.
    }

    func testNoTextReportForSuccessfulReadOrInvalidRanges() {
        let input = ObservationReadClient(actual: "abc", count: 3)
        var reports: [AmbientObservationTextReport] = []
        XCTAssertNotNil(AmbientInputSnapshot(source: "abc", input: input))
        _ = AmbientInputSnapshot.capture(source: "abc", input: input, onSourceText: { reports.append($0) })
        input.selection = NSRange(location: 1, length: 0)
        _ = AmbientInputSnapshot.capture(source: "abc", input: input, onSourceText: { reports.append($0) })
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(input.reads.count, 2) // Invalid selection must not trigger any substring read.
    }

    func testUnreadableTextIsDistinctFromEmptyAndAllowedUnreadablePathIsUnchanged() {
        let input = ObservationReadClient(actual: nil, count: 3)
        var report: AmbientObservationTextReport?
        let result = AmbientInputSnapshot.capture(source: "abc", input: input, onSourceText: { report = $0 })
        guard case .failure(.sourceUnavailable) = result else { return XCTFail("Expected unreadable") }
        XCTAssertNotNil(report)
        XCTAssertNil(report?.actual)
        report = nil
        _ = AmbientInputSnapshot.capture(source: "abc", input: input, allowUnreadableComposition: true,
            onSourceText: { report = $0 })
        XCTAssertNil(report)
        input.actual = ""
        _ = AmbientInputSnapshot.capture(source: "abc", input: input, onSourceText: { report = $0 })
        XCTAssertEqual(report?.actual, "")
    }

    @MainActor
    func testOptInRetentionClearingAndNoPreferencePersistence() {
        let domain = "org.sumibi.tests.observationDebug.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let life = AmbientConversionLifecycle(store: DecisionsSettingsStore(defaults: defaults),
            prepare: { _, _ in XCTFail("Diagnostics must not prepare a request"); throw DecisionsError.missingKey })
        let report = AmbientObservationTextReport(stage: .capture, source: "original text!", actual: "different text",
            ranges: .init(marked: NSRange(location: 0, length: 14), selection: NSRange(location: 14, length: 0)))
        XCTAssertFalse(life.debugTextEnabled)
        life.skipObservation(.sourceMismatch, debugText: report)
        XCTAssertNil(life.lastObservationText)
        life.setDebugTextEnabled(true)
        life.skipObservation(.sourceMismatch, debugText: report)
        life.stop() // Opening settings / changing focus must preserve the failure.
        XCTAssertEqual(life.lastObservationText, report)
        XCTAssertEqual(life.lastObservationBlock, .sourceMismatch)
        life.setDebugTextEnabled(false)
        XCTAssertNil(life.lastObservationText)
        life.setDebugTextEnabled(true)
        life.skipObservation(.sourceMismatch, debugText: report)
        life.beginDeliveryAttempt()
        XCTAssertNil(life.lastObservationText)
        life.skipObservation(.sourceMismatch, debugText: report)
        life.settingsChanged()
        XCTAssertNil(life.lastObservationText)
        life.skipObservation(.sourceMismatch, debugText: report)
        life.skipObservation(.secureInput)
        XCTAssertNil(life.lastObservationText)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        let fresh = AmbientConversionLifecycle(store: DecisionsSettingsStore(defaults: defaults))
        XCTAssertFalse(fresh.debugTextEnabled)
        XCTAssertNil(fresh.lastObservationText)
    }

    @MainActor
    func testNextObservationClearsOldTextEvenWhenAutomaticConversionIsDisabled() {
        let domain = "org.sumibi.tests.observationDebug.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let life = AmbientConversionLifecycle(store: DecisionsSettingsStore(defaults: defaults))
        life.setDebugTextEnabled(true)
        life.skipObservation(.sourceMismatch, debugText: .init(stage: .validation, source: "abc", actual: "xyz",
            ranges: .init(marked: NSRange(location: 0, length: 3), selection: NSRange(location: 3, length: 0))))
        life.observe(.init(observation: DecisionsObservation(text: "new", latestKey: "w")!,
            isCurrent: { true }, apply: { _ in XCTFail("Must not apply"); return false }))
        XCTAssertNil(life.lastObservationText)
    }
}

private final class ObservationReadClient: InputClient {
    var actual: String?
    let count: Int
    var selection: NSRange
    var reads: [NSRange] = []
    init(actual: String?, count: Int) {
        self.actual = actual; self.count = count; selection = NSRange(location: count, length: 0)
    }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { NSRange(location: 0, length: count) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        reads.append(range)
        XCTAssertEqual(range, markedRange())
        return actual.map { NSAttributedString(string: $0) }
    }
    func insertText(_ text: Any, replacementRange: NSRange) { XCTFail("Debug must not write") }
    func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange) { XCTFail("Debug must not write") }
    func lineRect(at index: Int) -> NSRect { XCTFail("Debug must not read coordinates"); return .zero }
}
