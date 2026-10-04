import Foundation
import SumibiCore
import os

/// All builds use the same privacy boundary. Never add String/Error payloads.
/// Review rule: no source/candidate/surrounding text, keys, URLs, raw responses,
/// raw error descriptions, key codes, bundle names or clipboard contents.
enum DiagnosticFailure: String, CaseIterable {
    case apiKeyMissing, consentMissing, overLimit, invalidEndpoint, invalidCredentials
    case rateLimited, serverError, httpError, emptyResponse, timedOut, offline, network

    init(_ error: ConversionError) {
        switch error {
        case .apiKeyMissing: self = .apiKeyMissing
        case .consentMissing: self = .consentMissing
        case .overLimit: self = .overLimit
        case .invalidEndpoint: self = .invalidEndpoint
        case .invalidCredentials: self = .invalidCredentials
        case .rateLimited: self = .rateLimited
        case .serverError: self = .serverError
        case .httpError: self = .httpError
        case .emptyResponse: self = .emptyResponse
        case .timedOut: self = .timedOut
        case .offline: self = .offline
        case .network: self = .network
        }
    }
}

/// Injection makes the filtering/privacy contract testable without reading OS logs.
struct DiagnosticReporter {
    static let preferenceKey = "DiagnosticLoggingEnabled"
    let detailed: () -> Bool
    let emit: (DiagnosticEvent, DiagnosticFailure?, [Int]) -> Void

    func record(_ event: DiagnosticEvent, reason: DiagnosticFailure? = nil,
                counters: @autoclosure () -> [Int] = []) {
        let enabled = detailed()
        guard event.isFailure || enabled else { return }
        // Default logs expose no per-input lengths/ranges, even on a failure.
        emit(event, reason, enabled ? counters() : [])
    }
}

enum DiagnosticLog {
    static var isDetailedEnabled: Bool {
        UserDefaults.standard.bool(forKey: DiagnosticReporter.preferenceKey)
    }
    private static let logger = Logger(subsystem: "org.sumibi.inputmethod.Sumibi", category: "diag")
    private static let reporter = DiagnosticReporter(
        detailed: { UserDefaults.standard.bool(forKey: DiagnosticReporter.preferenceKey) },
        emit: { event, reason, counters in
            let name = event.rawValue
            let category = reason?.rawValue ?? "none"
            let numbers = counters.map(String.init).joined(separator: ",")
            if event.isFailure {
                logger.error("event=\(name, privacy: .public) reason=\(category, privacy: .public) counters=[\(numbers, privacy: .public)]")
            } else {
                logger.notice("event=\(name, privacy: .public) counters=[\(numbers, privacy: .public)]")
            }
        })

    static func record(_ event: DiagnosticEvent, counters: @autoclosure () -> [Int] = []) {
        reporter.record(event, counters: counters())
    }

    static func conversionFailed(_ error: ConversionError) {
        reporter.record(.conversionFailed, reason: DiagnosticFailure(error))
    }
}
