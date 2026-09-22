import AppKit

/// 自前の候補一覧ウィンドウ。
///
/// macOS 27では、IMEが消費したキーごとに入力セッションが終了するため、`IMKCandidates`の
/// 選択API(`selectCandidate(withIdentifier:)`、`selectedCandidateString()`)が機能しない。
/// キーボードでの候補選択を成立させるため、描画と選択状態を自分で持つ。
final class CandidateWindow {
    private let panel: NSPanel
    private let list: CandidateListView
    /// 候補が確定されたときに呼ばれる。引数は候補の位置。
    var onSelect: ((Int) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var selectedIndex: Int { list.selectedIndex }
    var count: Int { list.candidates.count }

    init() {
        list = CandidateListView(frame: .zero)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = list
        list.onClick = { [weak self] index in self?.onSelect?(index) }
    }

    func show(candidates: [String], selected: Int, topLeft: NSPoint) {
        list.candidates = candidates
        list.selectedIndex = max(0, min(candidates.count - 1, selected))
        let size = list.fittingSize
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(topLeft) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
            // 画面下にはみ出す場合は、行の上側へ出す。
            if origin.y < visible.minY { origin.y = topLeft.y }
            origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        list.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func move(by delta: Int) {
        guard !list.candidates.isEmpty else { return }
        list.selectedIndex = max(0, min(list.candidates.count - 1, list.selectedIndex + delta))
        list.needsDisplay = true
    }

    /// セッション終了で隠された場合に、同じ内容と選択位置のまま出し直す。
    func reshow() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class CandidateListView: NSView {
    var candidates: [String] = []
    var selectedIndex = 0
    var onClick: ((Int) -> Void)?

    private let rowHeight: CGFloat = 22
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 6
    private let font = NSFont.systemFont(ofSize: 14)

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let widest = candidates.reduce(CGFloat(80)) { widest, candidate in
            max(widest, (candidate as NSString).size(withAttributes: [.font: font]).width)
        }
        return NSSize(width: ceil(widest) + horizontalPadding * 2,
                      height: CGFloat(candidates.count) * rowHeight + verticalPadding * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.stroke()

        for (index, candidate) in candidates.enumerated() {
            let row = rowRect(at: index)
            var color = NSColor.labelColor
            if index == selectedIndex {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 3, dy: 0), xRadius: 4, yRadius: 4).fill()
                color = .alternateSelectedControlTextColor
            }
            let text = candidate as NSString
            let size = text.size(withAttributes: [.font: font])
            text.draw(at: NSPoint(x: row.minX + horizontalPadding,
                                  y: row.midY - size.height / 2),
                      withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = candidates.indices.first(where: { rowRect(at: $0).contains(point) }) else { return }
        selectedIndex = index
        needsDisplay = true
        onClick?(index)
    }

    private func rowRect(at index: Int) -> NSRect {
        NSRect(x: 0, y: verticalPadding + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }
}
