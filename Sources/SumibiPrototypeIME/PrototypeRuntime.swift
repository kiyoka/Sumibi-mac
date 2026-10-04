import AppKit
import InputMethodKit
import SumibiPrototypeCore

/// Shared for IMK controller recreation observed on macOS 27, not independent documents.
/// The active input route owns this state; real target changes clear it before reuse.
/// All mutable state and IMK/UI access run on the main thread. Network work is asynchronous.
final class PrototypeRuntime {
    static let shared = PrototypeRuntime()
    let state = InputSession()
    let replacement = TextReplacementTracker()
    lazy var conversion = ConversionLifecycle(session: state)
    lazy var candidates = CandidatePresenter()
    var rescuedText = ""
    var deferredControls: [String] = []
    var lastError: String?
    var lastConsumedAt = Date.distantPast
    /// Prefer the newest controller; keep the last handler as a client fallback.
    weak var latest: PrototypeInputController?
    var lastHandler: PrototypeInputController?
    var lastInput: (any IMKTextInput)?
    var isEditingUserDictionary = false
    var selectionRange: NSRange?
    var originalCommitted = false
    var commandTapTimer: DispatchSourceTimer?

    /// Shared cancellation path used by the IMK adapter and fake-client regression tests.
    func cancelComposition() -> [SessionEffect] {
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
        conversion.cancel()
        candidates.hide()
        // Already committed originals stay in the old client; rescue only queued text.
        let effects = state.cancelForTargetChange(rescueMarked: rescueMarked && !originalCommitted)
        originalCommitted = false
        for case .rescueText(let text) in effects { rescuedText += text }
        replacement.anchor = nil
        replacement.pendingTarget = nil
    }
}
