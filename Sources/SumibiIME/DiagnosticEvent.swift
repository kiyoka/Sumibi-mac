import Foundation

/// Fixed vocabulary: no caller-controlled text or raw errors may enter the log.
enum DiagnosticEvent: String, CaseIterable {
    case controllerCreated
    case controllerReleased
    case controllerActivated
    case keyHandled
    case compositionCancelled
    case resultFlushedOnKey
    case candidateKeyConsumed
    case candidateMoved
    case selectionConversionStarted
    case commandTap
    case compositionCommitted
    case controllerDeactivated
    case candidatesReshown
    case candidateChosen
    case deliveryRetried
    case deliveryRangeChecked
    case targetChanged
    case selectionUnreadable
    case clientPokeSkipped
    case clientPoked
    case resultFlushed
    case excludedApplication
    case targetValidated
    case targetReanchored
    case reanchorUnavailable
    case anchorMissing
    case substringUnavailable
    case targetMismatch
    case anchorRejected
    case candidatesShown
    case candidateCycled
    case conversionSucceeded
    case conversionFailed
    case deliveryTimer
    case iconMissing
    case loginToggleFailed
    case loginRegistrationFailed
    case loginStatus
    case loginRegistered
    case deliveryUnavailable
    case overLimit

    var isFailure: Bool {
        switch self {
        case .conversionFailed, .deliveryUnavailable, .targetChanged, .selectionUnreadable,
             .iconMissing, .loginToggleFailed, .loginRegistrationFailed, .overLimit: true
        default: false
        }
    }
}
