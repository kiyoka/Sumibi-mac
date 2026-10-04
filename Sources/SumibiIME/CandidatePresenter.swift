import AppKit
import InputMethodKit
import SumibiCore
import os

private let diag = Logger(subsystem: "org.sumibi.inputmethod.Sumibi", category: "diag")

/// Window boundary used by the presenter; a test double requires no NSApplication/window.
protocol CandidateDisplaying: AnyObject {
    var onSelect: ((Int) -> Void)? { get set }
    var isVisible: Bool { get }
    var selectedIndex: Int { get }
    var count: Int { get }
    func show(candidates: [String], dictionaryCandidates: Set<String>, selected: Int, topLeft: NSPoint)
    func move(by delta: Int)
    func reshow()
    func hide()
}

/// Shared across IMK recreation, accessed only on the main thread.
/// Owns candidate presentation/selection, never writes to an input client.
final class CandidatePresenter {
    private let suppliedWindow: (any CandidateDisplaying)?
    private lazy var window: any CandidateDisplaying = suppliedWindow ?? CandidateWindow()
    private(set) var shouldBeVisible = false
    var dictionaryCandidates: Set<String> = []
    var lastLineRect: NSRect?
    var isVisible: Bool { window.isVisible }
    var selectedIndex: Int { window.selectedIndex }
    var count: Int { window.count }

    init(window: (any CandidateDisplaying)? = nil) { suppliedWindow = window }

    func show(candidates: [String], in input: any InputClient, onSelect: @escaping (Int) -> Void) {
        let rect = lineRectNearCaret(in: input) ?? lastLineRect
        let topLeft = rect.map { NSPoint(x: $0.minX, y: $0.minY) } ?? NSEvent.mouseLocation
        show(candidates: candidates, topLeft: topLeft, onSelect: onSelect)
        diag.notice("showCandidates count=\(candidates.count, privacy: .public) visible=\(self.isVisible, privacy: .public) anchor=\(rect.map { NSStringFromRect($0) } ?? "none", privacy: .public) topLeft=\(NSStringFromPoint(topLeft), privacy: .public)")
    }

    func show(candidates: [String], topLeft: NSPoint, onSelect: @escaping (Int) -> Void) {
        window.onSelect = onSelect
        window.show(candidates: candidates, dictionaryCandidates: dictionaryCandidates, selected: 0, topLeft: topLeft)
        shouldBeVisible = true
    }

    func move(by delta: Int) { window.move(by: delta) }
    func reshow() { window.reshow() }

    func hide() {
        shouldBeVisible = false
        window.hide()
    }

    func choose(at index: Int, session: InputSession, canReplacePrevious: Bool) -> [SessionEffect] {
        guard session.candidateStrings.indices.contains(index) else { return [] }
        return session.chooseCandidate(session.candidateStrings[index], canReplacePrevious: canReplacePrevious)
    }

    func cycle(session: InputSession, canReplacePrevious: Bool) -> [SessionEffect] {
        guard count > 0 else { return [] }
        let index = (selectedIndex + 1) % count
        guard session.candidateStrings.indices.contains(index) else { return [] }
        let effects = session.chooseCandidate(session.candidateStrings[index], canReplacePrevious: canReplacePrevious,
                                             keepCandidates: true)
        diag.notice("cycleCandidate index=\(index, privacy: .public) effects=\(effects.count, privacy: .public)")
        guard !effects.isEmpty else {
            hide()
            return []
        }
        window.move(by: index - selectedIndex)
        return effects
    }

    /// Just before the caret, then at the caret, using screen-coordinate line rectangles.
    private func lineRectNearCaret(in input: any InputClient) -> NSRect? {
        let caret = input.selectedRange().location
        guard caret != NSNotFound else { return nil }
        for index in [caret - 1, caret] where index >= 0 {
            let rect = input.lineRect(at: index)
            if rect.height > 0 { return rect }
        }
        return nil
    }
}
