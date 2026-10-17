import XCTest
import AppKit
@testable import SumibiIME

final class CaretDecisionCueTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 800, height: 600)

    @MainActor
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Cue did not finish")
    }

    @MainActor
    func testShowUsesCurrentCaretCoordinatesWithoutReadingOrWritingText() {
        let window = FakeCaretCueWindow()
        let cue = CaretDecisionCue(window: window)
        let input = CueInputClient()
        cue.show(in: input, screens: [screen], isCurrent: { true })
        XCTAssertTrue(cue.isVisible)
        XCTAssertEqual(window.frames, [NSRect(x: 108, y: 168, width: 28, height: 28)])
        XCTAssertEqual(input.indices, [2])
        XCTAssertEqual(window.kinds, [.accepted])
        cue.hide()
        XCTAssertFalse(cue.isVisible)
        XCTAssertEqual(window.hides, 1)
    }

    @MainActor
    func testUnavailableInvalidOffscreenAndStalePositionsNeverShow() {
        for rect in [NSRect.zero, NSRect(x: 900, y: 100, width: 0, height: 20),
                     NSRect(x: 20, y: 20, width: 0, height: 201),
                     NSRect(x: CGFloat.nan, y: 20, width: 0, height: 20)] {
            let window = FakeCaretCueWindow()
            let cue = CaretDecisionCue(window: window)
            let input = CueInputClient()
            input.rect = rect
            cue.show(in: input, screens: [screen], isCurrent: { true })
            XCTAssertTrue(window.frames.isEmpty)
            XCTAssertFalse(cue.isVisible)
        }
        let window = FakeCaretCueWindow()
        let cue = CaretDecisionCue(window: window)
        let input = CueInputClient()
        input.selection = NSRange(location: NSNotFound, length: 0)
        cue.show(in: input, screens: [screen], isCurrent: { true })
        input.selection = NSRange(location: 3, length: 0)
        cue.show(in: input, screens: [screen], isCurrent: { false })
        cue.show(in: input, screens: [], isCurrent: { true })
        XCTAssertTrue(window.frames.isEmpty)
    }

    func testPlacementStaysOnSelectedScreenAndMovesAboveBottomEdge() {
        let bottom = CaretDecisionCue.frame(near: NSRect(x: 795, y: 1, width: 0, height: 20), screens: [screen])
        XCTAssertEqual(bottom, NSRect(x: 772, y: 25, width: 28, height: 28))
        let left = NSRect(x: -800, y: 0, width: 800, height: 600)
        let frame = CaretDecisionCue.frame(near: NSRect(x: -700, y: 200, width: 0, height: 20), screens: [screen, left])
        XCTAssertEqual(frame, NSRect(x: -692, y: 168, width: 28, height: 28))
        XCTAssertTrue(left.contains(frame!))
    }

    @MainActor
    func testCueExpiresWithoutReappearing() async {
        let window = FakeCaretCueWindow()
        let cue = CaretDecisionCue(window: window)
        cue.show(in: CueInputClient(), screens: [screen], isCurrent: { true })
        await wait { !cue.isVisible }
        XCTAssertEqual(window.frames.count, 1)
        XCTAssertEqual(window.hides, 1)
    }

    @MainActor
    func testInputOrTargetChangeHidesCueOnNextPoll() async {
        let window = FakeCaretCueWindow()
        let cue = CaretDecisionCue(window: window)
        var current = true
        cue.show(in: CueInputClient(), screens: [screen], isCurrent: { current })
        current = false
        await wait { !cue.isVisible }
        XCTAssertEqual(window.hides, 1)
    }

    @MainActor
    func testOldExpirationCannotHideNewCue() async {
        let window = FakeCaretCueWindow()
        let cue = CaretDecisionCue(window: window)
        cue.show(in: CueInputClient(), screens: [screen], isCurrent: { true })
        try? await Task.sleep(nanoseconds: 400_000_000)
        cue.show(in: CueInputClient(), kind: .error, screens: [screen], isCurrent: { true })
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(cue.isVisible)
        XCTAssertEqual(window.frames.count, 2)
        XCTAssertEqual(window.kinds, [.accepted, .error])
        await wait { !cue.isVisible }
        XCTAssertEqual(window.hides, 2)
    }

    @MainActor
    func testErrorCueUsesSameSafePlacementAndExpiresWithoutTouchingText() async {
        let window = FakeCaretCueWindow()
        let cue = CaretDecisionCue(window: window)
        let input = CueInputClient()
        cue.show(in: input, kind: .error, screens: [screen], isCurrent: { true })
        XCTAssertEqual(window.kinds, [.error])
        XCTAssertEqual(window.frames, [NSRect(x: 108, y: 168, width: 28, height: 28)])
        await wait { !cue.isVisible }
        XCTAssertEqual(window.hides, 1)
        input.rect = .zero
        cue.show(in: input, kind: .error, screens: [screen], isCurrent: { true })
        XCTAssertEqual(window.frames.count, 1)
    }

    func testErrorAndAcceptedCuesHaveDistinctColorsShapesAndSafeLabels() {
        XCTAssertEqual(CaretCueKind.accepted.glyph, "✓")
        XCTAssertEqual(CaretCueKind.error.glyph, "!")
        XCTAssertEqual(CaretCueKind.accepted.color, .systemGreen)
        XCTAssertEqual(CaretCueKind.error.color, .systemRed)
        XCTAssertTrue(CaretCueKind.error.accessibilityLabel.contains("エラー"))
        XCTAssertNotEqual(CaretCueKind.accepted.accessibilityLabel, CaretCueKind.error.accessibilityLabel)
    }
}

private final class FakeCaretCueWindow: CaretCueDisplaying {
    var frames: [NSRect] = []
    var hides = 0
    var kinds: [CaretCueKind] = []
    func show(frame: NSRect, kind: CaretCueKind) { frames.append(frame); kinds.append(kind) }
    func hide() { hides += 1 }
}

private final class CueInputClient: InputClient {
    var selection = NSRange(location: 3, length: 0)
    var rect = NSRect(x: 100, y: 200, width: 0, height: 20)
    var indices: [Int] = []
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { NSRange(location: 0, length: 3) }
    func lineRect(at index: Int) -> NSRect { indices.append(index); return rect }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        XCTFail("Cue must not read text"); return nil
    }
    func insertText(_ text: Any, replacementRange: NSRange) { XCTFail("Cue must not write text") }
    func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange) { XCTFail("Cue must not write marked text") }
}
