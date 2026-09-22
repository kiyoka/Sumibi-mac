import AppKit
import Carbon
import InputMethodKit
import SumibiPrototypeCore
import os

/// 試作の挙動を追うための診断ログ。利用者の入力内容は記録せず、文字数・キーコード・
/// インスタンス識別子・範囲だけを出す。`log show --predicate 'subsystem == "..."'`で読む。
private let diag = Logger(subsystem: "dev.kiyoka.inputmethod.SumibiPrototypeProbe1", category: "diag")

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

/// macOS 27のIMKは、IMEが消費したキーごとにセッション(コントローラー)を終了して作り直す。
/// 入力途中の状態はコントローラーではなく、プロセス全体で共有するこの型に置く。
final class PrototypeRuntime {
    static let shared = PrototypeRuntime()
    let state = InputSession()
    fileprivate var anchor: ReplacementAnchor?
    fileprivate var pendingTarget: PendingTarget?
    fileprivate lazy var candidateWindow: CandidateWindow = CandidateWindow()
    fileprivate var rescuedText = ""
    fileprivate var deferredControls: [String] = []
    fileprivate var lastError: String?
    fileprivate var finishTimer: DispatchWorkItem?
    fileprivate var lastConsumedAt = Date.distantPast
    /// 最も新しいコントローラー。応答待ちの完了時に、生きている入力先へ書き込むために使う。
    fileprivate weak var latest: PrototypeInputController?
    /// 最後にキーを処理したコントローラー。セッション終了後も入力先の窓口が使えるかを調べるため強参照で保持する。
    fileprivate var lastHandler: PrototypeInputController?
    /// 未確定文字列の表示中に得られた行矩形。確定後は入力先が矩形を返さないことがあるため、候補窓の位置に流用する。
    fileprivate var lastLineRect: NSRect?
    /// 最後にキーを受け取った入力先。セッション終了後に新しいコントローラーが現れない間の予備として使う。
    fileprivate var lastInput: (any IMKTextInput)?
    fileprivate var finishRetries = 0
    fileprivate var panelTopLeft: NSPoint?
    /// 候補窓を出しているべきか。セッション終了で隠れた場合に出し直す判断に使う。
    fileprivate var panelShouldBeVisible = false
    /// 保留中の応答が返ってくる(模擬では返ってきたことにする)時刻。
    fileprivate var pendingReadyAt: Date?
    /// 初回変換の応答待ちの間、原文を通常の文字として確定済みかどうか。
    fileprivate var originalCommitted = false
}

@objc(SumibiPrototypeInputController)
final class PrototypeInputController: IMKInputController {
    private let runtime = PrototypeRuntime.shared
    private var state: InputSession { runtime.state }
    private var anchor: ReplacementAnchor? { get { runtime.anchor } set { runtime.anchor = newValue } }
    private var pendingTarget: PendingTarget? { get { runtime.pendingTarget } set { runtime.pendingTarget = newValue } }
    private var candidateWindow: CandidateWindow { runtime.candidateWindow }
    private var rescuedText: String { get { runtime.rescuedText } set { runtime.rescuedText = newValue } }
    private var deferredControls: [String] { get { runtime.deferredControls } set { runtime.deferredControls = newValue } }
    private var lastError: String? { get { runtime.lastError } set { runtime.lastError = newValue } }

    /// ログ上でコントローラーのインスタンスを見分けるための短い識別子。
    private let diagID = String(UUID().uuidString.prefix(4))

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        runtime.latest = self
        // 新しいセッションは入力先が生きているので、返っている応答があればここで完了させる。
        DispatchQueue.main.async { [weak self] in self?.completeIfReady(reason: "new session") }
        let clientObject = inputClient as AnyObject?
        let bundleID = (inputClient as? IMKTextInput)?.bundleIdentifier() ?? "nil"
        diag.notice("init id=\(self.diagID, privacy: .public) client=\(clientObject.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public) clientAddr=\(clientObject.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "nil", privacy: .public) bundle=\(bundleID, privacy: .public)")
    }

    deinit { diag.notice("deinit id=\(self.diagID, privacy: .public)") }

    override func activateServer(_ sender: Any!) {
        diag.notice("activateServer id=\(self.diagID, privacy: .public) marked=\(self.state.marked.count)")
        runtime.latest = self
        DispatchQueue.main.async { [weak self] in self?.completeIfReady(reason: "activate") }
        super.activateServer(sender)
    }

    override func handle(_ event: NSEvent, client sender: Any) -> Bool {
        runtime.latest = self
        runtime.lastHandler = self
        let before = state.marked.count
        diag.notice("handle id=\(self.diagID, privacy: .public) type=\(event.type.rawValue) keyCode=\(event.keyCode) markedBefore=\(before) isIMKTextInput=\(sender is IMKTextInput)")
        guard event.type == .keyDown, let input = sender as? IMKTextInput else { return false }
        runtime.lastInput = input
        // 応答は返っているのに、セッション終了で入力先へ書き込めなかった場合は、生きた入力先が確実にあるこの時点で完了させる。
        if let request = state.pending, let readyAt = runtime.pendingReadyAt, Date() >= readyAt {
            diag.notice("completing pending request on key event id=\(self.diagID, privacy: .public) request=\(request.id, privacy: .public)")
            let panelWasVisible = runtime.panelShouldBeVisible
            finishRequest(NSNumber(value: request.id), using: input)
            // この反映で候補窓が開いたなら、このキーの役目は果たされている。
            // 続けて同じキーを解釈すると、開いた窓を閉じて同じ要求をやり直してしまう。
            if !panelWasVisible, runtime.panelShouldBeVisible {
                diag.notice("key consumed by flush that opened the candidate window")
                runtime.lastConsumedAt = Date()
                return true
            }
        }
        // 候補窓の表示中は、移動・決定・取消のキーを自前の選択位置で処理する。それ以外のキーでは候補窓を閉じる。
        if runtime.panelShouldBeVisible {
            switch event.keyCode {
            case 125, 126:
                candidateWindow.move(by: event.keyCode == 125 ? 1 : -1)
                diag.notice("candidate move key=\(event.keyCode, privacy: .public) index=\(self.candidateWindow.selectedIndex, privacy: .public)")
                runtime.lastConsumedAt = Date()
                return true
            case 123, 124:
                runtime.lastConsumedAt = Date()
                return true
            case 36, 76:
                chooseCandidate(at: candidateWindow.selectedIndex, in: input)
                runtime.lastConsumedAt = Date()
                return true
            case 53:
                hideCandidatePanel()
                runtime.lastConsumedAt = Date()
                return true
            default:
                hideCandidatePanel()
            }
        }
        guard let key = decode(event) else {
            diag.notice("handle id=\(self.diagID, privacy: .public) decode=nil")
            if state.pending != nil { cancelForTargetChange() }
            return false
        }
        let wasPending = state.pending != nil
        let effects = state.receive(key, canReplacePrevious: validatesPrevious(in: input))
        // 応答待ち中のキーは溜めるだけで入力先へ書き込まない。次のセッションを作らせるためにつつく。
        if wasPending, effects.isEmpty { pokeClient(input) }
        let result = apply(effects, to: input)
        if result { runtime.lastConsumedAt = Date() }
        diag.notice("handle id=\(self.diagID, privacy: .public) effects=\(effects.count) markedAfter=\(self.state.marked.count) consumed=\(result)")
        return result
    }

    override func commitComposition(_ sender: Any!) {
        diag.notice("commitComposition id=\(self.diagID, privacy: .public) marked=\(self.state.marked.count) isIMKTextInput=\(sender is IMKTextInput)")
        guard let input = sender as? IMKTextInput else { return }
        // 確定直後にも未確定文字列なしで呼ばれる。そのとき直前の変換結果と置換位置を消すと、2回目の変換ができなくなる。
        guard !state.marked.isEmpty, !runtime.originalCommitted else { return }
        input.insertText(state.marked, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        cancelForTargetChange(rescueMarked: false)
    }

    override func deactivateServer(_ sender: Any!) {
        diag.notice("deactivateServer id=\(self.diagID, privacy: .public) marked=\(self.state.marked.count) isIMKTextInput=\(sender is IMKTextInput)")
        // 消費したキーの直後に来る終了通知は、実際のフォーカス移動ではないので状態を維持する。
        if Date().timeIntervalSince(runtime.lastConsumedAt) < 0.3 {
            super.deactivateServer(sender)
            // 自前の候補窓はIMKの管理外だが、アプリの非アクティブ化で隠れた場合に備えて出し直す。
            if runtime.panelShouldBeVisible, !candidateWindow.isVisible {
                candidateWindow.reshow()
                diag.notice("candidate window re-shown id=\(self.diagID, privacy: .public)")
            }
            return
        }
        if let input = sender as? IMKTextInput, !state.marked.isEmpty, !runtime.originalCommitted {
            input.insertText(state.marked, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            cancelForTargetChange(rescueMarked: false)
        } else {
            cancelForTargetChange()
        }
        hideCandidatePanel()
        super.deactivateServer(sender)
    }

    /// 自前の候補窓から候補が選ばれたときの処理。キーボードとマウスの両方から使う。
    private func chooseCandidate(at index: Int, in input: (any IMKTextInput)?) {
        hideCandidatePanel()
        guard state.candidateStrings.indices.contains(index), let input = input ?? liveInput() else { return }
        let candidate = state.candidateStrings[index]
        let effects = state.chooseCandidate(candidate, canReplacePrevious: validatesPrevious(in: input))
        diag.notice("chooseCandidate index=\(index, privacy: .public) effects=\(effects.count, privacy: .public)")
        _ = apply(effects, to: input)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Sumibi Prototype")
        menu.addItem(withTitle: "Sumibi設定…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
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

    @objc private func openSettings() {
        MainActor.assumeIsolated { SettingsWindowController.shared.show() }
    }

    @objc private func copyRescuedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rescuedText, forType: .string)
    }

    @objc private func discardRescuedText() { rescuedText = "" }

    private func scheduleFinish(id: Int, delay: TimeInterval, retry: Bool = false) {
        if !retry {
            runtime.finishRetries = 0
            runtime.pendingReadyAt = Date().addingTimeInterval(delay)
        }
        runtime.finishTimer?.cancel()
        let work = DispatchWorkItem { [runtime] in
            let target = runtime.latest ?? runtime.lastHandler
            diag.notice("finish timer id=\(id) retry=\(runtime.finishRetries) latest=\(runtime.latest != nil) target=\(target?.diagID ?? "none", privacy: .public)")
            target?.finishRequest(NSNumber(value: id))
        }
        runtime.finishTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// セッション終了後は入力先へ書き込めない瞬間がある。生きた入力先が現れるまで0.25秒ごとに再試行する(最大約60秒)。
    private func liveInput() -> (any IMKTextInput)? {
        for candidate in [client() as (any IMKTextInput)?, runtime.latest?.client() as (any IMKTextInput)?, runtime.lastInput] {
            if let candidate, candidate.selectedRange().location != NSNotFound { return candidate }
        }
        return nil
    }

    private func finishRequest(_ number: NSNumber, using explicit: (any IMKTextInput)? = nil) {
        guard let request = state.pending, request.id == number.intValue else { return }
        guard let input = explicit ?? liveInput() else {
            runtime.finishRetries += 1
            diag.notice("finishRequest: no live client (retry \(self.runtime.finishRetries, privacy: .public))")
            if runtime.finishRetries > 240 {
                lastError = "入力先に接続できないため変換結果を適用できませんでした"
                cancelForTargetChange()
            } else {
                scheduleFinish(id: number.intValue, delay: 0.25, retry: true)
            }
            return
        }
        let selection = input.selectedRange()
        let marked = input.markedRange()
        diag.notice("finishRequest: selected=\(selection.location, privacy: .public),\(selection.length, privacy: .public) marked=\(marked.location, privacy: .public),\(marked.length, privacy: .public) target=\(self.pendingTarget?.selection.location ?? -1, privacy: .public),\(self.pendingTarget?.selection.length ?? -1, privacy: .public)")
        guard validatesPendingTarget(request, in: input) else {
            diag.notice("finishRequest: target validation failed")
            cancelForTargetChange()
            return
        }
        pendingTarget = nil
        let succeeds = Self.responseSucceeds
        let effects: [SessionEffect]
        if !succeeds { lastError = "試作の変換要求が失敗またはタイムアウトしました" }
        switch request.kind {
        case .first:
            let result = succeeds ? mockFirst(request.source) : nil
            var firstEffects = state.completeFirst(id: request.id, result: result)
            if runtime.originalCommitted {
                runtime.originalCommitted = false
                if result != nil {
                    // 確定済みの原文を、変換結果で置換する。
                    if case .commit(let text)? = firstEffects.first {
                        firstEffects[0] = .replacePrevious(from: request.source, to: text)
                    }
                } else if let a = anchor {
                    // 失敗: 原文を未確定文字列に戻し、応答中に溜めた文字を続けられるようにする。
                    let range = NSRange(location: a.end - a.text.utf16.count, length: a.text.utf16.count)
                    input.setMarkedText(request.source, selectionRange: NSRange(location: request.source.utf16.count, length: 0),
                                        replacementRange: range)
                    anchor = nil
                }
            }
            effects = firstEffects
        case .alternatives:
            effects = state.completeAlternatives(
                id: request.id,
                alternatives: succeeds ? mockAlternatives(request.source) : nil
            )
        }
        _ = apply(effects, to: input)
    }

    /// 応答モード。`defaults write dev.kiyoka.inputmethod.SumibiPrototypeProbe1 PrototypeResponseMode -string <mode>`で切り替える。
    /// success(0.6秒で成功)、slow(5秒で成功。応答待ち中の入力を手で試すため)、failure、timeout(60秒)。
    private static var responseMode: String {
        UserDefaults.standard.string(forKey: "PrototypeResponseMode") ?? "success"
    }

    private static var responseDelay: TimeInterval {
        switch responseMode {
        case "timeout": 60.0
        case "slow": 5.0
        default: 0.6
        }
    }

    private static var responseSucceeds: Bool {
        responseMode == "success" || responseMode == "slow"
    }

    private func mockFirst(_ source: String) -> String {
        switch source.lowercased() {
        case "ohayou": "おはよう"
        case "arigatou": "ありがとう"
        default: "【\(source)】"
        }
    }

    private func mockAlternatives(_ source: String) -> [String] {
        (1...10).map { "候補\($0)・\(mockFirst(source))" }
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
                let markedStart = input.markedRange().location
                if markedStart != NSNotFound {
                    var rect = NSRect.zero
                    _ = input.attributes(forCharacterIndex: markedStart, lineHeightRectangle: &rect)
                    if rect.height > 0 { runtime.lastLineRect = rect }
                }
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
                // 原文をいったん通常の文字として確定し、応答が来たらその範囲を置換する。
                // 未確定のままだと原文が入力先のUndo履歴に入らず、Undoで原文へ戻せない。
                input.insertText(source, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                runtime.originalCommitted = true
                let caret = input.selectedRange()
                if caret.location != NSNotFound, caret.length == 0 {
                    anchor = ReplacementAnchor(end: caret.location, text: source)
                } else {
                    anchor = nil
                }
                pendingTarget = PendingTarget(requestID: id, selection: caret, expectedText: source, kind: .first)
                let delay = Self.responseDelay
                scheduleFinish(id: id, delay: delay)
            case .startAlternatives(let id, _, let current):
                pendingTarget = PendingTarget(requestID: id, selection: input.selectedRange(),
                                              expectedText: current,
                                              kind: .alternatives)
                // 追加候補の要求では入力先へ何も書かないため、次のセッションを作らせるためにつつく。
                pokeClient(input)
                let delay = Self.responseDelay
                scheduleFinish(id: id, delay: delay)
            case .showCandidates:
                let anchorRect = lineRectNearCaret(in: input) ?? runtime.lastLineRect
                let topLeft = anchorRect.map { NSPoint(x: $0.minX, y: $0.minY) } ?? NSEvent.mouseLocation
                candidateWindow.onSelect = { [weak self] index in self?.chooseCandidate(at: index, in: nil) }
                candidateWindow.show(candidates: state.candidateStrings, selected: 0, topLeft: topLeft)
                runtime.panelShouldBeVisible = true
                runtime.panelTopLeft = topLeft
                diag.notice("showCandidates count=\(self.state.candidateStrings.count, privacy: .public) visible=\(self.candidateWindow.isVisible, privacy: .public) anchor=\(anchorRect.map { NSStringFromRect($0) } ?? "none", privacy: .public) topLeft=\(NSStringFromPoint(topLeft), privacy: .public)")
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

    /// カーソル直前、なければカーソル位置の行矩形(画面座標)。どちらも取得できなければnil。
    private func lineRectNearCaret(in input: IMKTextInput) -> NSRect? {
        let caret = input.selectedRange().location
        guard caret != NSNotFound else { return nil }
        for index in [caret - 1, caret] where index >= 0 {
            var rect = NSRect.zero
            _ = input.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
            if rect.height > 0 { return rect }
        }
        return nil
    }

    /// 入力先へ無害な書き込みを行い、新しい入力セッションを作らせる。
    ///
    /// macOS 27では、キーを消費するとセッションが終了する。応答待ち中のキーは状態機械に溜めるだけで
    /// 入力先へ何も書かないため、そのままでは新しいセッションが生まれず、応答が返っても書き込む先がない。
    /// 入力先への書き込みがセッション再作成の契機になることが分かったので、明示的に空文字を書く。
    private func pokeClient(_ input: (any IMKTextInput)?) {
        // 方式は`defaults write dev.kiyoka.inputmethod.SumibiPrototypeProbe1 PrototypePokeStyle -string <style>`で選ぶ。
        // marked(既定): 文書を変えない空の未確定文字列のみ。insert: 空文字の挿入のみ。both: 両方。off: 何もしない。
        let style = UserDefaults.standard.string(forKey: "PrototypePokeStyle") ?? "marked"
        guard style != "off", let input else {
            diag.notice("poke skipped style=\(style, privacy: .public)")
            return
        }
        let caret = input.selectedRange()
        guard caret.location != NSNotFound else { return }
        let notFound = NSRange(location: NSNotFound, length: NSNotFound)
        // 空文字の挿入は文書の変更として扱われ、入力先のUndoのまとまりを壊すことがある
        // (TextEditでは利用者自身の入力まで1つのUndoにまとめられた)。既定では行わない。
        if style == "marked" || style == "both" {
            input.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
        }
        if style == "insert" || style == "both" {
            input.insertText("", replacementRange: NSRange(location: caret.location, length: caret.length))
        }
        diag.notice("poke client style=\(style, privacy: .public) at \(caret.location, privacy: .public),\(caret.length, privacy: .public)")
    }

    /// 応答が返っていて、このコントローラーの入力先が生きていれば、保留中の変換を完了させる。
    private func completeIfReady(reason: String) {
        guard let request = state.pending, let readyAt = runtime.pendingReadyAt, Date() >= readyAt,
              let input = client() as (any IMKTextInput)?, input.selectedRange().location != NSNotFound else { return }
        diag.notice("completing pending request on \(reason, privacy: .public) id=\(self.diagID, privacy: .public) request=\(request.id, privacy: .public)")
        finishRequest(NSNumber(value: request.id), using: input)
    }

    private func hideCandidatePanel() {
        runtime.panelShouldBeVisible = false
        candidateWindow.hide()
    }

    private func validatesPrevious(in input: IMKTextInput) -> Bool {
        guard let previous = state.previous else { return false }
        return validatesAnchor(in: input, expected: previous.result)
    }

    private func validatesPendingTarget(_ request: PendingRequest, in input: IMKTextInput) -> Bool {
        guard let target = pendingTarget,
              target.requestID == request.id,
              target.kind == request.kind else { return false }
        // 初回変換も追加候補も、確定済みの文字列(アンカー)を置換する。
        let ok = target.selection == input.selectedRange() && validatesAnchor(in: input, expected: target.expectedText)
        diag.notice("validate \(request.kind == .first ? "first" : "alternatives", privacy: .public): ok=\(ok, privacy: .public)")
        return ok
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
        runtime.finishTimer?.cancel()
        runtime.finishTimer = nil
        hideCandidatePanel()
        // 原文を確定済みなら、すでに入力先にあるので保留文字として救済しない。
        let effects = state.cancelForTargetChange(rescueMarked: rescueMarked && !runtime.originalCommitted)
        runtime.originalCommitted = false
        for case .rescueText(let text) in effects { rescuedText += text }
        anchor = nil
        pendingTarget = nil
    }
}
