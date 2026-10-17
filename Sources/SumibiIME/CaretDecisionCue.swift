import AppKit

enum CaretCueKind {
    case accepted, error
    var glyph: String { self == .accepted ? "✓" : "!" }
    var color: NSColor { self == .accepted ? .systemGreen : .systemRed }
    var accessibilityLabel: String {
        self == .accepted ? "Decisionsが変換対象と判定しました" : "Sumibiの変換エラーが発生しました"
    }
}

protocol CaretCueDisplaying: AnyObject {
    func show(frame: NSRect, kind: CaretCueKind)
    func hide()
}

/// Presentation only: no text reads/writes, activation or fallback to stale/mouse positions.
final class CaretDecisionCue {
    private let suppliedWindow: (any CaretCueDisplaying)?
    private lazy var window: any CaretCueDisplaying = suppliedWindow ?? CaretCueWindow()
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var isVisible = false

    init(window: (any CaretCueDisplaying)? = nil) { suppliedWindow = window }

    func show(in input: any InputClient, kind: CaretCueKind = .accepted,
              screens: [NSRect] = NSScreen.screens.map(\.visibleFrame),
              isCurrent: @escaping () -> Bool) {
        hide()
        guard isCurrent() else { return }
        let selection = input.selectedRange()
        guard selection.location != NSNotFound, selection.location >= 0 else { return }
        let indices = [selection.location - 1, selection.location].filter { $0 >= 0 }
        var resolved: NSRect?
        for index in indices {
            if let frame = Self.frame(near: input.lineRect(at: index), screens: screens) {
                resolved = frame
                break
            }
        }
        guard let frame = resolved, isCurrent() else { return }
        window.show(frame: frame, kind: kind)
        isVisible = true
        let token = generation
        task = Task { @MainActor [weak self] in
            for tick in 1...12 {
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { return }
                guard let self, self.generation == token else { return }
                if tick == 12 || !isCurrent() { self.hide(); return }
            }
        }
    }

    func hide() {
        generation &+= 1
        task?.cancel()
        task = nil
        if isVisible { window.hide() }
        isVisible = false
    }

    static func frame(near rect: NSRect, screens: [NSRect]) -> NSRect? {
        guard [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width >= 0, rect.height > 0, rect.height <= 200,
              let screen = screens.first(where: {
                  $0.width >= 28 && $0.height >= 28 && $0.contains(NSPoint(x: rect.minX, y: rect.midY))
              }) else { return nil }
        let side: CGFloat = 28
        let x = min(max(screen.minX, rect.minX + 8), screen.maxX - side)
        var y = rect.minY - side - 4
        if y < screen.minY { y = rect.maxY + 4 }
        y = min(max(screen.minY, y), screen.maxY - side)
        return NSRect(x: x, y: y, width: side, height: side)
    }

    deinit { task?.cancel() }
}

/// Non-key and click-through. Ordering this panel never activates Sumibi.
private final class CaretCueWindow: NSPanel, CaretCueDisplaying {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        title = CaretCueKind.accepted.accessibilityLabel
        let cue = CaretCueView(frame: .zero)
        cue.setAccessibilityLabel(title)
        contentView = cue
    }

    func show(frame: NSRect, kind: CaretCueKind) {
        title = kind.accessibilityLabel
        if let cue = contentView as? CaretCueView {
            cue.kind = kind
            cue.setAccessibilityLabel(title)
            cue.needsDisplay = true
        }
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

private final class CaretCueView: NSView {
    var kind = CaretCueKind.accepted
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        kind.color.setStroke()
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        circle.lineWidth = 2
        circle.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 19), .foregroundColor: kind.color
        ]
        let text = kind.glyph as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                  withAttributes: attributes)
    }
}
