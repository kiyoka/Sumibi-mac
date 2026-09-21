import AppKit
import Carbon
import InputMethodKit
import SumibiPrototypeCore

private struct ReplacementAnchor {
    var end: Int
    var text: String
}

private struct PendingTarget {
    let requestID: Int
    let selection: NSRange
    let expectedText: String
    let kind: PendingRequest.Kind
}

@objc(SumibiPrototypeInputController)
final class PrototypeInputController: IMKInputController {
    private let state = InputSession()
    private var anchor: ReplacementAnchor?
    private var pendingTarget: PendingTarget?
    private var candidatePanel: IMKCandidates?
    private var rescuedText = ""
    private var deferredControls: [String] = []
    private var lastError: String?

    override func handle(_ event: NSEvent, client sender: Any) -> Bool {
        guard event.type == .keyDown, let input = sender as? IMKTextInput else { return false }
        guard let key = decode(event) else {
            if state.pending != nil { cancelForTargetChange() }
            return false
        }
        let effects = state.receive(key, canReplacePrevious: validatesPrevious(in: input))
        return apply(effects, to: input)
    }

    override func commitComposition(_ sender: Any!) {
        guard let input = sender as? IMKTextInput else { return }
        if !state.marked.isEmpty {
            input.insertText(state.marked, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        cancelForTargetChange(rescueMarked: false)
    }

    override func deactivateServer(_ sender: Any!) {
        if let input = sender as? IMKTextInput, !state.marked.isEmpty {
            input.insertText(state.marked, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            cancelForTargetChange(rescueMarked: false)
        } else {
            cancelForTargetChange()
        }
        candidatePanel?.hide()
        super.deactivateServer(sender)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        state.candidateStrings.map { NSAttributedString(string: $0) }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let candidateString, let input = client() else { return }
        let effects = state.chooseCandidate(candidateString.string, canReplacePrevious: validatesPrevious(in: input))
        _ = apply(effects, to: input)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Sumibi Prototype")
        if !rescuedText.isEmpty {
            menu.addItem(withTitle: "保留文字をコピー", action: #selector(copyRescuedText), keyEquivalent: "")
            menu.addItem(withTitle: "保留文字を破棄", action: #selector(discardRescuedText), keyEquivalent: "")
        }
        if !deferredControls.isEmpty {
            let item = NSMenuItem(title: "未適用の制御キー: \(deferredControls.joined(separator: ", "))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let lastError {
            let item = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    @objc private func copyRescuedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rescuedText, forType: .string)
    }

    @objc private func discardRescuedText() { rescuedText = "" }

    @objc private func finishRequest(_ number: NSNumber) {
        guard let request = state.pending, request.id == number.intValue else { return }
        guard let input = client() else {
            cancelForTargetChange()
            return
        }
        guard validatesPendingTarget(request, in: input) else {
            cancelForTargetChange()
            return
        }
        pendingTarget = nil
        let mode = UserDefaults.standard.string(forKey: "PrototypeResponseMode") ?? "success"
        let effects: [SessionEffect]
        if mode != "success" { lastError = "試作の変換要求が失敗またはタイムアウトしました" }
        switch request.kind {
        case .first:
            effects = state.completeFirst(id: request.id, result: mode == "success" ? mockFirst(request.source) : nil)
        case .alternatives:
            effects = state.completeAlternatives(
                id: request.id,
                alternatives: mode == "success" ? mockAlternatives(request.source) : nil
            )
        }
        _ = apply(effects, to: input)
    }

    private func mockFirst(_ source: String) -> String {
        switch source.lowercased() {
        case "ohayou": "おはよう"
        case "arigatou": "ありがとう"
        default: "【\(source)】"
        }
    }

    private func mockAlternatives(_ source: String) -> [String] {
        (1...10).map { "\(mockFirst(source))・候補\($0)" }
    }

    private func decode(_ event: NSEvent) -> InputKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.control), event.charactersIgnoringModifiers?.lowercased() == "j" {
            return .convert
        }
        if event.keyCode == 36 || event.keyCode == 76 { return .enter }
        if event.keyCode == 51 { return .backspace }
        if !modifiers.intersection([.command, .control, .option, .function]).isEmpty { return nil }
        guard let text = event.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return .text(text)
    }

    private func apply(_ effects: [SessionEffect], to input: IMKTextInput) -> Bool {
        var passToClient = false
        for effect in effects {
            switch effect {
            case .marked(let text):
                input.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            case .commit(let text):
                input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                if state.previous?.result == text {
                    let selection = input.selectedRange()
                    if selection.location != NSNotFound, selection.length == 0 {
                        anchor = ReplacementAnchor(end: selection.location, text: text)
                    }
                }
            case .passEnter(let deferred):
                if deferred { deferredControls.append("Enter") } else { passToClient = true }
            case .passBackspace(let deferred):
                if deferred { deferredControls.append("Backspace") } else { passToClient = true }
            case .passConvert(let deferred):
                if deferred { deferredControls.append("Control-J") } else { passToClient = true }
            case .startFirst(let id, let source):
                pendingTarget = PendingTarget(requestID: id, selection: input.selectedRange(),
                                              expectedText: source, kind: .first)
                let mode = UserDefaults.standard.string(forKey: "PrototypeResponseMode") ?? "success"
                let delay = mode == "timeout" ? 60.0 : 0.6
                perform(#selector(finishRequest(_:)), with: NSNumber(value: id), afterDelay: delay)
            case .startAlternatives(let id, _, let current):
                pendingTarget = PendingTarget(requestID: id, selection: input.selectedRange(),
                                              expectedText: current,
                                              kind: .alternatives)
                let mode = UserDefaults.standard.string(forKey: "PrototypeResponseMode") ?? "success"
                let delay = mode == "timeout" ? 60.0 : 0.6
                perform(#selector(finishRequest(_:)), with: NSNumber(value: id), afterDelay: delay)
            case .showCandidates:
                if candidatePanel == nil {
                    candidatePanel = IMKCandidates(server: server(), panelType: kIMKSingleColumnScrollingCandidatePanel)
                }
                candidatePanel?.update()
                candidatePanel?.show(kIMKLocateCandidatesBelowHint)
            case .replacePrevious(let old, let new):
                guard validatesAnchor(in: input, expected: old), let anchor else { break }
                let range = NSRange(location: anchor.end - anchor.text.utf16.count, length: anchor.text.utf16.count)
                input.insertText(new, replacementRange: range)
                let selection = input.selectedRange()
                if selection.location != NSNotFound, selection.length == 0 {
                    self.anchor = ReplacementAnchor(end: selection.location, text: new)
                } else {
                    self.anchor = nil
                }
            case .overLimit:
                lastError = "変換対象は1,000文字までです"
            case .rescueText(let text):
                rescuedText += text
            }
        }
        return !passToClient
    }

    private func validatesPrevious(in input: IMKTextInput) -> Bool {
        guard let previous = state.previous else { return false }
        return validatesAnchor(in: input, expected: previous.result)
    }

    private func validatesPendingTarget(_ request: PendingRequest, in input: IMKTextInput) -> Bool {
        guard let target = pendingTarget,
              target.requestID == request.id,
              target.kind == request.kind,
              target.selection == input.selectedRange() else { return false }
        if request.kind == .alternatives {
            return validatesAnchor(in: input, expected: target.expectedText)
        }
        guard target.selection.location != NSNotFound,
              target.selection.location >= target.expectedText.utf16.count else { return false }
        let range = NSRange(location: target.selection.location - target.expectedText.utf16.count,
                            length: target.expectedText.utf16.count)
        return input.attributedSubstring(from: range)?.string == target.expectedText
    }

    private func validatesAnchor(in input: IMKTextInput, expected: String) -> Bool {
        guard let anchor,
              anchor.text == expected,
              anchor.end >= anchor.text.utf16.count else { return false }
        let selection = input.selectedRange()
        guard selection.location == anchor.end, selection.length == 0 else { return false }
        let range = NSRange(location: anchor.end - anchor.text.utf16.count, length: anchor.text.utf16.count)
        return input.attributedSubstring(from: range)?.string == anchor.text
    }

    private func cancelForTargetChange(rescueMarked: Bool = true) {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        let effects = state.cancelForTargetChange(rescueMarked: rescueMarked)
        for case .rescueText(let text) in effects { rescuedText += text }
        anchor = nil
        pendingTarget = nil
    }
}
