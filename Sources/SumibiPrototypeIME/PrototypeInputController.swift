import AppKit
import Carbon
import InputMethodKit
import SumibiPrototypeCore
import os

/// 試作の挙動を追うための診断ログ。利用者の入力内容は記録せず、文字数・キーコード・
/// インスタンス識別子・範囲だけを出す。`log show --predicate 'subsystem == "..."'`で読む。
private let diag = Logger(subsystem: "org.sumibi.inputmethod.Sumibi", category: "diag")

private struct ReplacementAnchor {
    var end: Int
    var text: String
    /// 入力先の文書上での長さ(UTF-16)。ターミナルで折り返して表示された原文は、改行と字下げの分だけ`text`より長い。
    var span: Int

    init(end: Int, text: String, span: Int? = nil) {
        self.end = end
        self.text = text
        self.span = span ?? text.utf16.count
    }

    var range: NSRange { NSRange(location: end - span, length: span) }
}

/// 変換要求の結果。入力先へ書き込めるようになるまで保持する。
private enum PendingOutcome {
    case first(String)
    case alternatives([String])
    case failure(ConversionError)
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
    /// 応答が返った時刻。返るまでは nil。
    fileprivate var pendingReadyAt: Date?
    /// 返ってきた応答。入力先へ書き込める状態になるまで持っておく。
    fileprivate var pendingOutcome: PendingOutcome?
    /// 実行中の変換要求。入力先が変わったら取り消す。
    fileprivate var conversionTask: Task<Void, Never>?
    /// 選択変換を始めたときの選択範囲。
    fileprivate var selectionRange: NSRange?
    /// 初回変換の応答待ちの間、原文を通常の文字として確定済みかどうか。
    fileprivate var originalCommitted = false
    /// 右Commandを押してから離すまでの見張り。
    fileprivate var commandTapTimer: DispatchSourceTimer?
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
        // 対象外のアプリのセッションは、応答の書き込み先にしない。
        if !isExcluded(inputClient) { runtime.latest = self }
        // 新しいセッションは入力先が生きているので、返っている応答があればここで完了させる。
        DispatchQueue.main.async { [weak self] in self?.completeIfReady(reason: "new session") }
        let clientObject = inputClient as AnyObject?
        let bundleID = (inputClient as? IMKTextInput)?.bundleIdentifier() ?? "nil"
        diag.notice("init id=\(self.diagID, privacy: .public) client=\(clientObject.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public) clientAddr=\(clientObject.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "nil", privacy: .public) bundle=\(bundleID, privacy: .public)")
    }

    deinit { diag.notice("deinit id=\(self.diagID, privacy: .public)") }

    override func activateServer(_ sender: Any!) {
        diag.notice("activateServer id=\(self.diagID, privacy: .public) marked=\(self.state.marked.count)")
        if isExcluded(sender) {
            leaveForExcludedApplication()
            super.activateServer(sender)
            return
        }
        runtime.latest = self
        DispatchQueue.main.async { [weak self] in self?.completeIfReady(reason: "activate") }
        super.activateServer(sender)
    }

    /// 修飾キーだけの押し下げ(右Commandのタップ)も受け取る。
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent, client sender: Any) -> Bool {
        // 対象外のアプリでは、どのキーも加工せず入力先へ渡す。`Control + J`もアプリ自身の操作として動く。
        if isExcluded(sender) {
            leaveForExcludedApplication()
            return false
        }
        runtime.latest = self
        runtime.lastHandler = self
        let before = state.marked.count
        diag.notice("handle id=\(self.diagID, privacy: .public) type=\(event.type.rawValue) keyCode=\(event.keyCode) modifiers=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue, privacy: .public) markedBefore=\(before) isIMKTextInput=\(sender is IMKTextInput)")
        if event.type == .flagsChanged {
            if let input = sender as? IMKTextInput { watchCommandTap(event, in: input) }
            return false
        }
        guard event.type == .keyDown, let input = sender as? IMKTextInput else { return false }
        return process(decode(event), keyCode: event.keyCode, in: input)
    }

    /// 解釈したキーを処理する。右Commandのタップは、キーコードなしの`Control + J`としてここへ来る。
    private func process(_ decoded: InputKey?, keyCode: UInt16?, in input: IMKTextInput) -> Bool {
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
            switch keyCode {
            case 125?, 126?:
                candidateWindow.move(by: keyCode == 125 ? 1 : -1)
                diag.notice("candidate move key=\(keyCode ?? 0, privacy: .public) index=\(self.candidateWindow.selectedIndex, privacy: .public)")
                runtime.lastConsumedAt = Date()
                return true
            case 123?, 124?:
                runtime.lastConsumedAt = Date()
                return true
            case 36?, 76?:
                chooseCandidate(at: candidateWindow.selectedIndex, in: input)
                runtime.lastConsumedAt = Date()
                return true
            case 53?:
                hideCandidatePanel()
                runtime.lastConsumedAt = Date()
                return true
            default:
                // ターミナルは未確定文字列がないとき矢印キーやEnterをIMEへ回さないので、届く変換キーと数字キーでも選べるようにする。
                // 変換キーは次の候補へ移り、その場で書き換える。ターミナルでは決定のキーも届かないため。
                if decoded == .convert {
                    cycleCandidate(in: input)
                    runtime.lastConsumedAt = Date()
                    return true
                }
                if case .text(let text)? = decoded, let number = Int(text), number >= 1, number <= min(9, candidateWindow.count) {
                    chooseCandidate(at: number - 1, in: input)
                    runtime.lastConsumedAt = Date()
                    return true
                }
                hideCandidatePanel()
            }
        }
        guard let key = decoded else {
            diag.notice("handle id=\(self.diagID, privacy: .public) decode=nil")
            if state.pending != nil { cancelForTargetChange() }
            return false
        }
        // 未確定文字列がなく、追加候補にもならない`Control + J`は、選択範囲の変換として扱う。
        if key == .convert, state.pending == nil, state.marked.isEmpty, !validatesPrevious(in: input),
           let selection = readSelection(in: input) {
            let effects = state.convertSelection(selection.text)
            runtime.selectionRange = selection.range
            let consumed = apply(effects, to: input)
            if consumed { runtime.lastConsumedAt = Date() }
            diag.notice("convert selection length=\(selection.text.count, privacy: .public) effects=\(effects.count, privacy: .public)")
            return consumed
        }
        let wasPending = state.pending != nil
        let effects = state.receive(key, canReplacePrevious: validatesPrevious(in: input))
        // 応答待ち中のキーは溜めるだけで入力先へ書き込まない。次のセッションを作らせるためにつつく。
        if wasPending, effects.isEmpty { pokeClient(input) }
        // 「かな」キーは変換するものがなくても入力先へ渡さない。ABC配列の入力先では意味を持たない。
        let result = apply(effects, to: input) || keyCode == Self.kanaKeyCode
        if result { runtime.lastConsumedAt = Date() }
        diag.notice("handle id=\(self.diagID, privacy: .public) effects=\(effects.count) markedAfter=\(self.state.marked.count) consumed=\(result)")
        return result
    }

    /// 右Commandを押したら、離すまでキーボードの状態を見張る。離したことの通知は入力先によって届かないため使わない。
    /// 他のキーやクリックを挟まずに短く押して離したら、`Control + J`と同じ変換の操作として扱う。
    private func watchCommandTap(_ event: NSEvent, in input: IMKTextInput) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard event.keyCode == 54, flags.contains(.command) else { return }
        runtime.commandTapTimer?.cancel()
        let started = Date()
        let counts = Self.inputCounts()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
        timer.setEventHandler { [self] in
            let held = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
            let duration = Date().timeIntervalSince(started)
            if held, duration <= CommandTap.maximumDuration { return }
            timer.cancel()
            runtime.commandTapTimer = nil
            let tap = !held && CommandTap.isTap(duration: duration, onlyCommand: flags == .command,
                                                otherInput: Self.inputCounts() != counts)
            diag.notice("right command released tap=\(tap, privacy: .public) held=\(held, privacy: .public) duration=\(Int(duration * 1000), privacy: .public)ms")
            guard tap, !isExcluded(input), input.selectedRange().location != NSNotFound else { return }
            _ = process(.convert, keyCode: nil, in: input)
        }
        runtime.commandTapTimer = timer
        timer.resume()
    }

    /// JISキーボードの「かな」キー(kVK_JIS_Kana)。
    private static let kanaKeyCode: UInt16 = 104

    /// これまでに押されたキーとマウスボタンの累計。右Commandを押している間に増えたら、組み合わせ操作とみなす。
    private static func inputCounts() -> [UInt32] {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        }
    }

    override func commitComposition(_ sender: Any!) {
        diag.notice("commitComposition id=\(self.diagID, privacy: .public) marked=\(self.state.marked.count) isIMKTextInput=\(sender is IMKTextInput)")
        guard let input = sender as? IMKTextInput, !isExcluded(input) else { return }
        // 確定直後にも未確定文字列なしで呼ばれる。そのとき直前の変換結果と置換位置を消すと、2回目の変換ができなくなる。
        guard !state.marked.isEmpty, !runtime.originalCommitted else { return }
        input.insertText(state.marked, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        cancelForTargetChange(rescueMarked: false)
    }

    override func deactivateServer(_ sender: Any!) {
        diag.notice("deactivateServer id=\(self.diagID, privacy: .public) marked=\(self.state.marked.count) isIMKTextInput=\(sender is IMKTextInput)")
        // 対象外のアプリには何も書いていない。ここで状態を消すと、次に移った先の入力を壊しうる。
        if isExcluded(sender) {
            super.deactivateServer(sender)
            return
        }
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

    /// 候補窓の次の候補へ移り、候補窓を開いたまま入力先の文字列をその候補に書き換える。最後の候補の次は先頭へ戻る。
    private func cycleCandidate(in input: IMKTextInput) {
        guard candidateWindow.count > 0 else { return }
        let index = (candidateWindow.selectedIndex + 1) % candidateWindow.count
        guard state.candidateStrings.indices.contains(index) else { return }
        let effects = state.chooseCandidate(state.candidateStrings[index], canReplacePrevious: validatesPrevious(in: input),
                                            keepCandidates: true)
        diag.notice("cycleCandidate index=\(index, privacy: .public) effects=\(effects.count, privacy: .public)")
        // 書き換えられなければ(照合が通らなければ)、選択位置も動かさずに候補窓を閉じる。
        guard !effects.isEmpty else {
            hideCandidatePanel()
            return
        }
        candidateWindow.move(by: index - candidateWindow.selectedIndex)
        _ = apply(effects, to: input)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Sumibi")
        menu.addItem(withTitle: "Sumibi設定…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        if ExcludedApplications.contains((client() as? IMKTextInput)?.bundleIdentifier()) {
            let item = NSMenuItem(title: "Emacs.appではEmacs版のSumibiを使ってください", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
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

    /// 変換を要求し、結果が返ったら入力先へ届ける。
    private func startConversion(id: Int, request: ConversionRequest) {
        runtime.finishRetries = 0
        runtime.pendingReadyAt = nil
        runtime.pendingOutcome = nil
        runtime.conversionTask?.cancel()
        let kind: (ConversionResult) -> PendingOutcome = { result in
            switch request.mode {
            case .first: .first(result.candidates.first ?? "")
            case .alternatives: .alternatives(result.candidates)
            }
        }
        runtime.conversionTask = Task { [runtime] in
            let outcome = await ConversionCoordinator().convert(request)
            if Task.isCancelled { return }
            await MainActor.run {
                guard runtime.state.pending?.id == id else { return }
                switch outcome {
                case .success(let result):
                    runtime.pendingOutcome = kind(result)
                    diag.notice("conversion succeeded id=\(id) candidates=\(result.candidates.count)")
                case .failure(let error):
                    runtime.pendingOutcome = .failure(error)
                    diag.notice("conversion failed id=\(id) retryable=\(error.isRetryable)")
                }
                runtime.pendingReadyAt = Date()
                (runtime.latest ?? runtime.lastHandler)?.finishRequest(NSNumber(value: id))
            }
        }
    }

    private func scheduleFinish(id: Int, delay: TimeInterval, retry: Bool = false) {
        if !retry { runtime.finishRetries = 0 }
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
            if let candidate, !isExcluded(candidate), candidate.selectedRange().location != NSNotFound { return candidate }
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
        reanchorIfCaretLagged(request, in: input)
        if !validatesPendingTarget(request, in: input) {
            reportTargetMismatch(in: input)
            reanchorAtCaret(request, in: input)
        }
        guard validatesPendingTarget(request, in: input) else {
            diag.notice("finishRequest: target validation failed")
            cancelForTargetChange()
            return
        }
        guard let outcome = runtime.pendingOutcome else { return }
        pendingTarget = nil
        runtime.pendingOutcome = nil
        runtime.pendingReadyAt = nil
        if case .failure(let error) = outcome { lastError = error.message }
        let effects: [SessionEffect]
        switch request.kind {
        case .first:
            let result: String? = if case .first(let text) = outcome, !text.isEmpty { text } else { nil }
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
                    let range = a.range
                    input.setMarkedText(MarkedTextStyle.attributed(request.source), selectionRange: NSRange(location: request.source.utf16.count, length: 0),
                                        replacementRange: range)
                    anchor = nil
                }
            }
            effects = firstEffects
        case .alternatives:
            let alternatives: [String]? = if case .alternatives(let list) = outcome { list } else { nil }
            effects = state.completeAlternatives(id: request.id, alternatives: alternatives)
        case .selection:
            let result: String? = if case .first(let text) = outcome, !text.isEmpty { text } else { nil }
            effects = state.completeSelection(id: request.id, result: result)
            runtime.selectionRange = nil
        }
        _ = apply(effects, to: input)
    }

    private func decode(_ event: NSEvent) -> InputKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 「かな」キーも変換キーとして扱う。JISキーボードのかなキーのほか、Kanaryなどが右Commandのタップをかなキーに変えて送ってくる。
        if event.keyCode == Self.kanaKeyCode { return .convert }
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
                input.setMarkedText(MarkedTextStyle.attributed(text), selectionRange: NSRange(location: text.utf16.count, length: 0),
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
                if UserDefaults.standard.bool(forKey: "PrototypeDiagnoseText"), caret.location != NSNotFound {
                    let start = max(0, caret.location - source.utf16.count - 40)
                    let around = input.attributedSubstring(from: NSRange(location: start, length: caret.location - start))?.string ?? "(nil)"
                    diag.notice("text: after commit caret=\(caret.location, privacy: .public) \(start, privacy: .public)..<\(caret.location, privacy: .public)=[\(around.replacingOccurrences(of: "\n", with: "\\n"), privacy: .public)]")
                }
                startConversion(id: id, request: ConversionRequest(source: source))
            case .startAlternatives(let id, let source, let current):
                pendingTarget = PendingTarget(requestID: id, selection: input.selectedRange(),
                                              expectedText: current,
                                              kind: .alternatives)
                // 追加候補の要求では入力先へ何も書かないため、次のセッションを作らせるためにつつく。
                pokeClient(input)
                startConversion(id: id, request: ConversionRequest(source: source, mode: .alternatives,
                                                                   currentConversion: current))
            case .startSelection(let id, let source):
                // 選択範囲を同じ文字列で置き換える。表示は変わらないが、この書き込みが
                // 新しい入力セッションを作らせ、応答を届けられるようにする。
                // 置換位置の記録(アンカー)も、未確定文字列からの変換と同じ形になる。
                let range = runtime.selectionRange ?? input.selectedRange()
                input.insertText(source, replacementRange: range)
                let caret = input.selectedRange()
                if caret.location != NSNotFound, caret.length == 0 {
                    anchor = ReplacementAnchor(end: caret.location, text: source)
                } else {
                    anchor = ReplacementAnchor(end: range.location + range.length, text: source)
                }
                pendingTarget = PendingTarget(requestID: id, selection: input.selectedRange(),
                                              expectedText: source, kind: .selection)
                startConversion(id: id, request: ConversionRequest(source: source))
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
                let range = anchor.range
                input.insertText(new, replacementRange: range)
                // 置換後の位置は、書き込んだ範囲から決める。Chromeは書き込み直後に
                // 古いカーソル位置を返すことがあり、それを信じると次の置換位置がずれる。
                self.anchor = ReplacementAnchor(end: range.location + new.utf16.count, text: new)
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

    /// 選択範囲とその文字列。読めない入力先ではnilを返し、何も書き換えない。
    private func readSelection(in input: any IMKTextInput) -> (range: NSRange, text: String)? {
        let range = input.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard let text = input.attributedSubstring(from: range)?.string, !text.isEmpty else {
            diag.notice("selection could not be read length=\(range.length, privacy: .public)")
            lastError = "この入力先では、選択した文字列を読み取れませんでした。"
            return nil
        }
        return (range, text)
    }

    /// 入力先へ無害な書き込みを行い、新しい入力セッションを作らせる。
    ///
    /// macOS 27では、キーを消費するとセッションが終了する。応答待ち中のキーは状態機械に溜めるだけで
    /// 入力先へ何も書かないため、そのままでは新しいセッションが生まれず、応答が返っても書き込む先がない。
    /// 入力先への書き込みがセッション再作成の契機になることが分かったので、明示的に空文字を書く。
    private func pokeClient(_ input: (any IMKTextInput)?) {
        // 方式は`defaults write org.sumibi.inputmethod.Sumibi PrototypePokeStyle -string <style>`で選ぶ。
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
              let input = client() as (any IMKTextInput)?, !isExcluded(input),
              input.selectedRange().location != NSNotFound else { return }
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
        // いずれの要求も、記録した位置(アンカー)に記録した文字列がまだあることを確かめてから置換する。
        let ok = target.selection == input.selectedRange() && validatesAnchor(in: input, expected: target.expectedText)
        diag.notice("validate \(String(describing: request.kind), privacy: .public): ok=\(ok, privacy: .public)")
        return ok
    }

    /// ターミナルは書き込んだ文字を少し遅れて反映し、書き込んだ直後のカーソル位置は原文の手前のままになる。
    /// 応答時のカーソルが記録より原文の長さだけ後ろにあり、その直前に原文があれば、書き込みが反映されたものとして位置を改める。
    private func reanchorIfCaretLagged(_ request: PendingRequest, in input: IMKTextInput) {
        guard request.kind == .first, let target = pendingTarget, target.requestID == request.id,
              let anchor, anchor.text == target.expectedText, anchor.end == target.selection.location else { return }
        let length = anchor.text.utf16.count
        let selection = input.selectedRange()
        guard selection.length == 0, selection.location == anchor.end + length,
              input.attributedSubstring(from: NSRange(location: anchor.end, length: length))?.string == anchor.text else { return }
        diag.notice("finishRequest: caret caught up with the written source; re-anchoring")
        self.anchor = ReplacementAnchor(end: selection.location, text: anchor.text)
        pendingTarget = PendingTarget(requestID: target.requestID, selection: selection,
                                      expectedText: target.expectedText, kind: target.kind)
    }

    /// ターミナルで動く全画面のアプリ(Claude Codeなど)は、行の折り返しなどで画面を描き直し、文字の位置番号がずれる。
    /// 応答待ちの間に打ったキーは入力先へ書かずに溜めているので、書き込んだ文字はカーソルの直前に残っているはずである。
    /// カーソルの直前に記録した文字列があれば、そこを置換位置として記録し直す。
    private func reanchorAtCaret(_ request: PendingRequest, in input: IMKTextInput) {
        guard let target = pendingTarget, target.requestID == request.id, target.kind == request.kind,
              let anchor, anchor.text == target.expectedText else { return }
        let selection = input.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0,
              let span = wrappedSpan(of: anchor.text, endingAt: selection.location, in: input)
        else {
            diag.notice("reanchor at caret: source not found before caret=\(selection.location, privacy: .public)")
            return
        }
        diag.notice("reanchor at caret: moved anchor \(anchor.end, privacy: .public) -> \(selection.location, privacy: .public) span=\(span, privacy: .public)")
        self.anchor = ReplacementAnchor(end: selection.location, text: anchor.text, span: span)
        pendingTarget = PendingTarget(requestID: target.requestID, selection: selection,
                                      expectedText: target.expectedText, kind: target.kind)
    }

    /// `end`の直前に`text`があれば、その文書上の長さを返す。ターミナルが折り返しで挟んだ改行と字下げも含める。
    private func wrappedSpan(of text: String, endingAt end: Int, in input: IMKTextInput) -> Int? {
        let length = text.utf16.count
        // 折り返しは1行ごとに数文字増えるだけなので、原文の2倍を読めば足りる。
        let start = max(0, end - length * 2)
        guard end >= length,
              let window = input.attributedSubstring(from: NSRange(location: start, length: end - start))?.string
        else { return nil }
        return WrappedText.suffixLength(of: text, in: window)
    }

    /// 記録した位置の文字列が一致しなかったとき、入力先が何を返したかを内容を出さずに記録する。
    /// 返った長さ、最初に食い違う位置、その位置の文字の種類だけを出す。
    private func reportTargetMismatch(in input: IMKTextInput) {
        guard let anchor, anchor.end >= anchor.span else {
            diag.notice("mismatch: no anchor")
            return
        }
        let range = anchor.range
        guard let actual = input.attributedSubstring(from: range)?.string else {
            diag.notice("mismatch: substring unavailable range=\(range.location, privacy: .public),\(range.length, privacy: .public)")
            return
        }
        let expected = Array(anchor.text.unicodeScalars)
        let returned = Array(actual.unicodeScalars)
        let offset = zip(expected, returned).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(expected.count, returned.count)
        let kind: String
        if offset < returned.count {
            let scalar = returned[offset]
            kind = if CharacterSet.newlines.contains(scalar) { "newline" }
                else if CharacterSet.whitespaces.contains(scalar) { "space" }
                else if CharacterSet.controlCharacters.contains(scalar) { "control" }
                else if scalar.properties.generalCategory == .privateUse { "privateUse" }
                else if scalar.isASCII { "ascii" }
                else { "other" }
        } else {
            kind = "end"
        }
        diag.notice("mismatch: range=\(range.location, privacy: .public),\(range.length, privacy: .public) expectedScalars=\(expected.count, privacy: .public) returnedScalars=\(returned.count, privacy: .public) firstDiff=\(offset, privacy: .public) returnedKind=\(kind, privacy: .public)")
        reportTargetText(in: input, recorded: range, actual: actual)
    }

    /// 調査用。`defaults write org.sumibi.inputmethod.Sumibi PrototypeDiagnoseText -bool true`のときだけ、
    /// 入力先が返した文字列そのもの(入力内容と周囲の表示)を記録する。調べ終えたら`defaults delete`で戻す。
    private func reportTargetText(in input: IMKTextInput, recorded range: NSRange, actual: String) {
        guard UserDefaults.standard.bool(forKey: "PrototypeDiagnoseText"), let anchor else { return }
        let visible: (String) -> String = { text in
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t")
        }
        let caret = input.selectedRange().location
        let span = anchor.text.utf16.count + 40
        let start = max(0, caret == NSNotFound ? 0 : caret - span)
        let beforeCaret = caret == NSNotFound ? "" :
            input.attributedSubstring(from: NSRange(location: start, length: caret - start))?.string ?? "(nil)"
        diag.notice("text: expected=[\(visible(anchor.text), privacy: .public)]")
        diag.notice("text: recorded \(range.location, privacy: .public)+\(range.length, privacy: .public)=[\(visible(actual), privacy: .public)]")
        diag.notice("text: before caret \(start, privacy: .public)..<\(caret, privacy: .public)=[\(visible(beforeCaret), privacy: .public)]")
    }

    /// 記録した位置に記録した文字列があるかを確かめる。なければ、カーソルの直前にあるかを確かめて記録し直す。
    ///
    /// ターミナルで動く全画面のアプリ(Claude Codeなど)は、置換したあとも入力欄を描き直し、文字の位置番号がずれる。
    /// 候補の出し直しや候補の選択のときには、記録した位置に変換結果が読めない。変換結果のあとに打った文字は
    /// 直前の変換を取り消す(`previous`を消す)ので、変換結果が残っていればカーソルの直前にあるはずである。
    /// 記録した文字列と違う文字列は置換しないという安全性は変わらない。
    private func validatesAnchor(in input: IMKTextInput, expected: String) -> Bool {
        if anchorMatches(in: input, expected: expected) { return true }
        guard let anchor, anchor.text == expected else { return false }
        let selection = input.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0,
              let span = wrappedSpan(of: anchor.text, endingAt: selection.location, in: input) else { return false }
        diag.notice("anchor moved to caret: \(anchor.end, privacy: .public) -> \(selection.location, privacy: .public) span=\(span, privacy: .public)")
        self.anchor = ReplacementAnchor(end: selection.location, text: anchor.text, span: span)
        return true
    }

    private func anchorMatches(in input: IMKTextInput, expected: String) -> Bool {
        guard let anchor,
              anchor.text == expected,
              anchor.end >= anchor.span else { return false }
        let range = anchor.range
        // 入力先によって、置換したあとのカーソルの形が違う。メモは末尾のカーソル、Chromeは選択範囲が残る。
        // どちらも「記録した位置に記録した文字列がまだある」ことに変わりはないので、両方を認める。
        let selection = input.selectedRange()
        let caretAtEnd = selection.location == anchor.end && selection.length == 0
        guard caretAtEnd || selection == range else {
            diag.notice("anchor rejected: selection=\(selection.location, privacy: .public),\(selection.length, privacy: .public) anchor=\(range.location, privacy: .public),\(range.length, privacy: .public)")
            return false
        }
        guard let actual = input.attributedSubstring(from: range)?.string else { return false }
        if anchor.span == anchor.text.utf16.count { return actual == anchor.text }
        // 折り返して表示された原文は、記録した長さのまま、改行と字下げを除いて一致することを確かめる。
        return WrappedText.suffixLength(of: anchor.text, in: actual) == anchor.span
    }

    /// 入力先がSumibiの対象外のアプリか。仕様書の「3.5 対象外のアプリ」を参照する。
    ///
    /// Sumibi自身の設定画面も対象外として扱う。入力欄はURL・モデル名・APIキーだけで、どれも英数字のため変換は要らない。
    /// 未確定文字列のまま「設定を保存」を押すと、確定が保存に間に合わず、入力した値が空のまま保存されていた。
    private func isExcluded(_ client: Any?) -> Bool {
        let bundleID = (client as? IMKTextInput)?.bundleIdentifier()
        return ExcludedApplications.contains(bundleID) || isOwnApplication(bundleID)
    }

    private func isOwnApplication(_ bundleID: String?) -> Bool {
        guard let bundleID, let own = Bundle.main.bundleIdentifier else { return false }
        return bundleID.caseInsensitiveCompare(own) == .orderedSame
    }

    /// 対象外のアプリへ移ったとき、他のアプリで進めていた入力を、別アプリへの切り替えと同じく終える。
    /// 変換結果や待機中の文字を対象外のアプリへ書き込まない。
    private func leaveForExcludedApplication() {
        let active = state.pending != nil || !state.marked.isEmpty || state.previous != nil || runtime.panelShouldBeVisible
        guard active else { return }
        diag.notice("excluded application: ending the current input id=\(self.diagID, privacy: .public)")
        cancelForTargetChange()
    }

    private func cancelForTargetChange(rescueMarked: Bool = true) {
        runtime.finishTimer?.cancel()
        runtime.finishTimer = nil
        runtime.conversionTask?.cancel()
        runtime.conversionTask = nil
        runtime.pendingOutcome = nil
        runtime.pendingReadyAt = nil
        hideCandidatePanel()
        // 原文を確定済みなら、すでに入力先にあるので保留文字として救済しない。
        let effects = state.cancelForTargetChange(rescueMarked: rescueMarked && !runtime.originalCommitted)
        runtime.originalCommitted = false
        for case .rescueText(let text) in effects { rescuedText += text }
        anchor = nil
        pendingTarget = nil
    }
}
