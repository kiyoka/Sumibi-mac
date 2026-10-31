import AppKit
import InputMethodKit
import SumibiCore

/// Shared for IMK controller recreation observed on macOS 27, not independent documents.
/// The active input route owns this state; real target changes clear it before reuse.
/// All mutable state and IMK/UI access run on the main thread. Network work is asynchronous.
final class InputRuntime {
    static let shared = InputRuntime()
    let state = InputSession()
    let replacement = TextReplacementTracker()
    let feedback = ConversionFeedback()
    lazy var conversion = ConversionLifecycle(session: state, feedback: feedback)
    lazy var resultVerifier = ConversionResultVerifier(feedback: feedback)
    lazy var caretCue = CaretDecisionCue()
    lazy var ambient = AmbientConversionLifecycle(feedback: feedback,
        dismissCue: { [weak self] in self?.caretCue.hide() })
    lazy var candidates = CandidatePresenter()
    var rescuedText = ""
    var deferredControls: [String] = []
    var lastConsumedAt = Date.distantPast
    /// Prefer the newest controller; keep the last handler as a client fallback.
    weak var latest: SumibiInputController?
    var lastHandler: SumibiInputController?
    var lastInput: (any IMKTextInput)?
    var isEditingUserDictionary = false
    var selectionRange: NSRange?
    var originalCommitted = false
    var lastMarkedStart: Int?
    /// A committed-source read wait, not a manual request whose keys may be queued.
    var awaitingAmbientSourceID: Int?
    var commandTapTimer: DispatchSourceTimer?

    init() {
        feedback.onNotice = { [weak self] in
            guard let self, let controller = self.latest ?? self.lastHandler else { return }
            controller.showCaretErrorCue()
        }
    }

    static func isNavigationKey(_ keyCode: UInt16?) -> Bool {
        switch keyCode {
        case 123?, 124?, 125?, 126?, 115?, 119?, 116?, 121?: return true
        default: return false
        }
    }

    /// Run before flushing a ready conversion or forwarding movement to the client.
    /// Some clients discard marked text on movement; commit the original first.
    /// Candidate arrows belong to the candidate presenter, not document navigation.
    func prepareForNavigation(keyCode: UInt16?) -> [SessionEffect]? {
        guard Self.isNavigationKey(keyCode), !candidates.shouldBeVisible else { return nil }
        let effects = cancelComposition()
        _ = state.cancelForTargetChange(rescueMarked: false)
        return effects
    }

    func cancelAmbientSourceWaitForInput() {
        guard awaitingAmbientSourceID != nil else { return }
        // The original is already committed. New keys must be handled normally,
        // never queued behind the read-only wait or appended to the old source.
        cancelForTargetChange(rescueMarked: false)
    }

    /// Shared cancellation path used by the IMK adapter and fake-client regression tests.
    func cancelComposition() -> [SessionEffect] {
        lastMarkedStart = nil
        awaitingAmbientSourceID = nil
        resultVerifier.cancel()
        ambient.stop()
        let effects = state.cancelComposition(originalCommitted: originalCommitted)
        conversion.cancel()
        candidates.hide()
        replacement.anchor = nil
        replacement.pendingTarget = nil
        selectionRange = nil
        originalCommitted = false
        candidates.dictionaryCandidates = []
        return effects
    }

    func cancelForTargetChange(rescueMarked: Bool = true) {
        lastMarkedStart = nil
        awaitingAmbientSourceID = nil
        resultVerifier.cancel()
        ambient.stop()
        conversion.cancel()
        candidates.hide()
        // Already committed originals stay in the old client; rescue only queued text.
        let effects = state.cancelForTargetChange(rescueMarked: rescueMarked && !originalCommitted)
        originalCommitted = false
        for case .rescueText(let text) in effects { rescuedText += text }
        replacement.anchor = nil
        replacement.pendingTarget = nil
    }

    func isMarkedTextAlreadyCommitted(_ text: String, in input: any InputClient) -> Bool {
        guard let start = lastMarkedStart, start != NSNotFound, start >= 0 else { return false }
        let len = text.utf16.count
        guard len > 0 else { return false }
        let marked = input.markedRange()
        guard marked.location == NSNotFound || marked.length == 0 else { return false }
        let selection = input.selectedRange()
        let expectedRange = NSRange(location: start, length: len)
        let caretAtEnd = selection == NSRange(location: start + len, length: 0)
        guard caretAtEnd || selection == expectedRange else { return false }
        return input.attributedSubstring(from: expectedRange)?.string == text
    }
}
