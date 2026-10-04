import XCTest
import SumibiCore
@testable import SumibiIME

final class DiagnosticLogTests: XCTestCase {
    func testDefaultDropsEveryNormalEventWithoutEvaluatingCounters() {
        var evaluations = 0
        let reporter = DiagnosticReporter(detailed: { false }) { _, _, _ in
            XCTFail("Default must not log ordinary input operations")
        }
        func counters() -> [Int] { evaluations += 1; return [123] }
        for event in DiagnosticEvent.allCases where !event.isFailure {
            reporter.record(event, counters: counters())
        }
        XCTAssertEqual(evaluations, 0)
    }

    func testDefaultKeepsOnlyFailuresAndOmitsInputMetadata() {
        var events: [DiagnosticEvent] = []
        let reporter = DiagnosticReporter(detailed: { false }) { event, _, numbers in
            XCTAssertTrue(event.isFailure)
            XCTAssertTrue(numbers.isEmpty)
            events.append(event)
        }
        for event in DiagnosticEvent.allCases { reporter.record(event, counters: [123, 456]) }
        XCTAssertEqual(events, DiagnosticEvent.allCases.filter(\.isFailure))
        XCTAssertEqual(events.count, 8)
    }

    func testDetailsKeepFixedEventsAndIntegerMetadata() {
        var events: [DiagnosticEvent] = []
        let reporter = DiagnosticReporter(detailed: { true }) { event, _, numbers in
            events.append(event)
            XCTAssertEqual(numbers, [7, 12])
        }
        for event in DiagnosticEvent.allCases { reporter.record(event, counters: [7, 12]) }
        XCTAssertEqual(events, DiagnosticEvent.allCases)
    }

    func testPreferenceCanBeEnabledDisabledAndLegacyTextFlagHasNoEffect() throws {
        let domain = "org.sumibi.tests.diagnostics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var emitted = 0
        let reporter = DiagnosticReporter(
            detailed: { defaults.bool(forKey: DiagnosticReporter.preferenceKey) },
            emit: { _, _, _ in emitted += 1 })
        defaults.set(true, forKey: "PrototypeDiagnoseText")
        reporter.record(.keyHandled)
        XCTAssertEqual(emitted, 0)
        defaults.set(true, forKey: DiagnosticReporter.preferenceKey)
        reporter.record(.keyHandled)
        XCTAssertEqual(emitted, 1)
        defaults.set(false, forKey: DiagnosticReporter.preferenceKey)
        reporter.record(.keyHandled)
        XCTAssertEqual(emitted, 1)
        reporter.record(.targetChanged)
        XCTAssertEqual(emitted, 2)
    }

    func testEveryConversionFailureIsReducedToFixedCategoryInBothModes() {
        let errors: [ConversionError] = [
            .apiKeyMissing, .consentMissing, .overLimit(count: 777, limit: 123),
            .invalidEndpoint, .invalidCredentials, .rateLimited, .serverError(statusCode: 503),
            .httpError(statusCode: 418), .emptyResponse, .timedOut, .offline,
            .network("secret-input secret-candidate secret-key https://private.example/response")
        ]
        for enabled in [false, true] {
            var reasons: [DiagnosticFailure] = []
            let reporter = DiagnosticReporter(detailed: { enabled }) { event, reason, numbers in
                XCTAssertEqual(event, .conversionFailed)
                XCTAssertTrue(numbers.isEmpty)
                if let reason { reasons.append(reason) }
            }
            for error in errors { reporter.record(.conversionFailed, reason: DiagnosticFailure(error)) }
            XCTAssertEqual(reasons, DiagnosticFailure.allCases)
            let output = reasons.map(\.rawValue).joined(separator: ",")
            for forbidden in ["secret", "private.example", "777", "503", "418"] {
                XCTAssertFalse(output.contains(forbidden))
            }
        }
    }

    func testProductionSourceHasOnlyOneLoggingBoundaryAndNoRawTextSwitch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("PrototypeDiagnoseText"), file.path)
            if file.lastPathComponent != "DiagnosticLog.swift" {
                for forbidden in ["import os", "Logger(", "NSLog(", "print(", "logger.", "diag.notice", "log.error"] {
                    XCTAssertFalse(text.contains(forbidden), "\(file.path): \(forbidden)")
                }
            }
        }
    }
}
