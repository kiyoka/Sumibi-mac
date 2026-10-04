import XCTest
import AppKit
import SumibiPrototypeCore
@testable import SumibiPrototypeIME

final class CandidatePresenterTests: XCTestCase {
    func testShowHideAndReshowPreserveWindowSelection() {
        let window = FakeCandidateWindow()
        let presenter = CandidatePresenter(window: window)
        presenter.dictionaryCandidates = ["第二"]
        var chosen: Int?
        presenter.show(candidates: ["第一", "第二"], topLeft: NSPoint(x: 10, y: 20)) { chosen = $0 }
        XCTAssertTrue(presenter.shouldBeVisible)
        XCTAssertEqual(window.dictionaryCandidates, ["第二"])
        presenter.move(by: 1)
        window.isVisible = false // IMK deactivation can hide the panel.
        presenter.reshow()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(presenter.selectedIndex, 1)
        window.onSelect?(1)
        XCTAssertEqual(chosen, 1)
        presenter.hide()
        XCTAssertFalse(presenter.shouldBeVisible)
        XCTAssertFalse(window.isVisible)
    }

    func testCycleKeepsCandidatesAndWrapsAround() {
        let (presenter, _, session) = candidates()
        XCTAssertEqual(presenter.cycle(session: session, canReplacePrevious: true),
                       [.replacePrevious(from: "第一", to: "第二")])
        XCTAssertEqual(presenter.selectedIndex, 1)
        XCTAssertEqual(presenter.cycle(session: session, canReplacePrevious: true),
                       [.replacePrevious(from: "第二", to: "第一")])
        XCTAssertEqual(presenter.selectedIndex, 0)
        XCTAssertTrue(presenter.shouldBeVisible)
        XCTAssertEqual(session.candidateStrings, ["第一", "第二"])
    }

    func testInvalidTargetClosesPanelWithoutMovingOrReplacing() {
        let (presenter, _, session) = candidates()
        XCTAssertEqual(presenter.cycle(session: session, canReplacePrevious: false), [])
        XCTAssertEqual(presenter.selectedIndex, 0)
        XCTAssertEqual(session.previous?.result, "第一")
        XCTAssertFalse(presenter.shouldBeVisible)
    }

    func testChoosingCandidateClearsSessionCandidates() {
        let (presenter, _, session) = candidates()
        XCTAssertEqual(presenter.choose(at: 1, session: session, canReplacePrevious: true),
                       [.replacePrevious(from: "第一", to: "第二")])
        XCTAssertTrue(session.candidateStrings.isEmpty)
    }

    func testOutOfRangeChoiceDoesNotModifySession() {
        let (presenter, _, session) = candidates()
        XCTAssertEqual(presenter.choose(at: -1, session: session, canReplacePrevious: true), [])
        XCTAssertEqual(presenter.choose(at: 2, session: session, canReplacePrevious: true), [])
        XCTAssertEqual(session.previous?.result, "第一")
    }

    private func candidates() -> (CandidatePresenter, FakeCandidateWindow, InputSession) {
        let session = InputSession()
        _ = session.receive(.text("abc"))
        _ = session.receive(.convert)
        _ = session.completeFirst(id: session.pending!.id, result: "第一")
        _ = session.receive(.convert, canReplacePrevious: true)
        _ = session.completeAlternatives(id: session.pending!.id, alternatives: ["第二"])
        let window = FakeCandidateWindow()
        let presenter = CandidatePresenter(window: window)
        presenter.show(candidates: session.candidateStrings, topLeft: .zero) { _ in }
        return (presenter, window, session)
    }
}

private final class FakeCandidateWindow: CandidateDisplaying {
    var onSelect: ((Int) -> Void)?
    var isVisible = false
    var selectedIndex = 0
    var count = 0
    var dictionaryCandidates: Set<String> = []
    func show(candidates: [String], dictionaryCandidates: Set<String>, selected: Int, topLeft: NSPoint) {
        count = candidates.count
        self.dictionaryCandidates = dictionaryCandidates
        selectedIndex = selected
        isVisible = true
    }
    func move(by delta: Int) { selectedIndex = max(0, min(count - 1, selectedIndex + delta)) }
    func reshow() { isVisible = true }
    func hide() { isVisible = false }
}
