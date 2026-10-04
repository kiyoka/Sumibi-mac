import AppKit
import InputMethodKit

/// Only the read/write operations used by effects. Fake clients need no IMK server.
protocol InputClient {
    func selectedRange() -> NSRange
    func markedRange() -> NSRange
    func attributedSubstring(from range: NSRange) -> NSAttributedString?
    func insertText(_ text: Any, replacementRange: NSRange)
    func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange)
    func lineRect(at index: Int) -> NSRect
}

/// No new state/caching: every operation goes to the original explicit IMK client.
struct IMKInputClient: InputClient {
    let input: any IMKTextInput
    init(_ input: any IMKTextInput) { self.input = input }
    func selectedRange() -> NSRange { input.selectedRange() }
    func markedRange() -> NSRange { input.markedRange() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { input.attributedSubstring(from: range) }
    func insertText(_ text: Any, replacementRange: NSRange) { input.insertText(text, replacementRange: replacementRange) }
    func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange) {
        input.setMarkedText(text, selectionRange: selectionRange, replacementRange: replacementRange)
    }
    func lineRect(at index: Int) -> NSRect {
        var rect = NSRect.zero
        _ = input.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
        return rect
    }
}
