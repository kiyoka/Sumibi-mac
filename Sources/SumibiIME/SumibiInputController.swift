import AppKit
import Carbon
import InputMethodKit
import SumibiCore
import os

/// 入力処理の挙動を追うための診断ログ。通常版は入力内容を記録せず、文字数・キーコード・
/// インスタンス識別子・範囲だけを出す。`log show --predicate 'subsystem == "..."'`で読む。
private let diag = Logger(subsystem: "org.sumibi.inputmethod.Sumibi", category: "diag")

// Keep the registered Objective-C name for IMK compatibility.
@objc(SumibiPrototypeInputController)
final class SumibiInputController: IMKInputController {
    private let runtime = InputRuntime.shared
    private var state: InputSession { runtime.state }
    private var anchor: ReplacementAnchor? { get { runtime.replacement.anchor } set { runtime.replacement.anchor = newValue } }
    private var pendingTarget: PendingTarget? { get { runtime.replacement.pendingTarget } set { runtime.replacement.pendingTarget = newValue } }
    private var candidateWindow: CandidatePresenter { runtime.candidates }
    private var rescuedText: String { get { runtime.rescuedText } set { runtime.rescuedText = newValue } }
    private var deferredControls: [String] { get { runtime.deferredControls } set { runtime.deferredControls = newValue } }

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
        // 返っている応答を反映する前にEscを処理する。取消と結果の確定が競合しないようにする。
        if decoded == .cancel {
            if runtime.candidates.shouldBeVisible {
                hideCandidatePanel()
                runtime.lastConsumedAt = Date()
                return true
            }
            guard !state.marked.isEmpty || state.pending != nil else { return false }
            let effects = runtime.cancelComposition()
            _ = apply(effects, to: input)
            runtime.lastConsumedAt = Date()
            diag.notice("composition cancelled with Esc effects=\(effects.count, privacy: .public)")
            return true
        }
        // 応答は返っているのに、セッション終了で入力先へ書き込めなかった場合は、生きた入力先が確実にあるこの時点で完了させる。
        if let request = state.pending, let readyAt = runtime.conversion.readyAt, Date() >= readyAt {
            diag.notice("completing pending request on key event id=\(self.diagID, privacy: .public) request=\(request.id, privacy: .public)")
            let panelWasVisible = runtime.candidates.shouldBeVisible
            finishRequest(NSNumber(value: request.id), using: input)
            // この反映で候補窓が開いたなら、このキーの役目は果たされている。
            // 続けて同じキーを解釈すると、開いた窓を閉じて同じ要求をやり直してしまう。
            if !panelWasVisible, runtime.candidates.shouldBeVisible {
                diag.notice("key consumed by flush that opened the candidate window")
                runtime.lastConsumedAt = Date()
                return true
            }
        }
        // 候補窓の表示中は、移動・決定・取消のキーを自前の選択位置で処理する。それ以外のキーでは候補窓を閉じる。
        if runtime.candidates.shouldBeVisible {
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
            if runtime.candidates.shouldBeVisible, !candidateWindow.isVisible {
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
        let effects = candidateWindow.choose(at: index, session: state, canReplacePrevious: validatesPrevious(in: input))
        diag.notice("chooseCandidate index=\(index, privacy: .public) effects=\(effects.count, privacy: .public)")
        _ = apply(effects, to: input)
    }

    /// 候補窓の次の候補へ移り、候補窓を開いたまま入力先の文字列をその候補に書き換える。最後の候補の次は先頭へ戻る。
    private func cycleCandidate(in input: IMKTextInput) {
        guard candidateWindow.count > 0 else { return }
        let effects = candidateWindow.cycle(session: state, canReplacePrevious: validatesPrevious(in: input))
        _ = apply(effects, to: input)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Sumibi")
        menu.addItem(withTitle: "Sumibi設定…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        if ExcludedApplications.contains(client()?.bundleIdentifier()) {
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
        if let notice = runtime.feedback.notice {
            let item = NSMenuItem(title: notice.title, action: nil, keyEquivalent: "")
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

    /// ConversionLifecycle owns cancellation, ready results and retry scheduling.
    private func startConversion(id: Int, request: ConversionRequest) {
        let request = ConversionRequest(source: request.source, mode: request.mode,
                                        currentConversion: request.currentConversion,
                                        userDictionary: SettingsStore().loadUserDictionary())
        runtime.conversion.start(id: id, request: request) { [runtime] id in
            (runtime.latest ?? runtime.lastHandler)?.finishRequest(NSNumber(value: id))
        }
    }

    private func scheduleFinish(id: Int, delay: TimeInterval, retry: Bool = false) {
        runtime.conversion.scheduleFinish(id: id, delay: delay, retry: retry) { [runtime] id in
            (runtime.latest ?? runtime.lastHandler)?.finishRequest(NSNumber(value: id))
        }
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
            let shouldRetry = runtime.conversion.recordUnavailableClient()
            diag.notice("finishRequest: no live client (retry \(self.runtime.conversion.retryCount, privacy: .public))")
            if !shouldRetry {
                runtime.feedback.report(.inputUnavailable)
                cancelForTargetChange()
            } else {
                scheduleFinish(id: number.intValue, delay: 0.25, retry: true)
            }
            return
        }
        let selection = input.selectedRange()
        let marked = input.markedRange()
        diag.notice("finishRequest: selected=\(selection.location, privacy: .public),\(selection.length, privacy: .public) marked=\(marked.location, privacy: .public),\(marked.length, privacy: .public) target=\(self.pendingTarget?.selection.location ?? -1, privacy: .public),\(self.pendingTarget?.selection.length ?? -1, privacy: .public)")
        runtime.replacement.reanchorIfCaretLagged(request, in: ReplacementInput(input))
        if !runtime.replacement.validatesPendingTarget(request, in: ReplacementInput(input)) {
            runtime.replacement.reportTargetMismatch(in: ReplacementInput(input))
            runtime.replacement.reanchorAtCaret(request, in: ReplacementInput(input))
        }
        guard runtime.replacement.validatesPendingTarget(request, in: ReplacementInput(input)) else {
            diag.notice("finishRequest: target validation failed")
            cancelForTargetChange()
            return
        }
        guard let outcome = runtime.conversion.takeOutcome(id: request.id) else { return }
        pendingTarget = nil
        let effects: [SessionEffect]
        switch request.kind {
        case .first:
            runtime.candidates.dictionaryCandidates = []
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
            let alternatives: [String]?
            if case .alternatives(let result) = outcome {
                alternatives = result.candidates
                // 現在の確定結果は前回選んだ出所を維持する。今回の応答で同じ表記が
                // 別の出所から返っても、先頭に表示するのは既存の確定結果である。
                let current = state.previous?.result
                let currentWasDictionary = current.map(runtime.candidates.dictionaryCandidates.contains) ?? false
                runtime.candidates.dictionaryCandidates = result.dictionaryCandidates
                if let current {
                    if currentWasDictionary {
                        runtime.candidates.dictionaryCandidates.insert(current)
                    } else {
                        runtime.candidates.dictionaryCandidates.remove(current)
                    }
                }
            } else {
                alternatives = nil
                runtime.candidates.dictionaryCandidates = []
            }
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
        if event.keyCode == 53, modifiers.intersection([.shift, .command, .control, .option, .function]).isEmpty {
            return .cancel
        }
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
        InputEffectApplier(runtime: runtime,
                       startConversion: { [self] id, request in startConversion(id: id, request: request) },
                       pokeClient: { [self] _ in pokeClient(input) },
                       selectCandidate: { [weak self] index in self?.chooseCandidate(at: index, in: nil) },
                       diagnoseText: DevelopmentOptions.current.diagnoseText)
        .apply(effects, to: IMKInputClient(input))
    }

    /// 選択範囲とその文字列。読めない入力先ではnilを返し、何も書き換えない。
    private func readSelection(in input: any IMKTextInput) -> (range: NSRange, text: String)? {
        let range = input.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard let text = input.attributedSubstring(from: range)?.string, !text.isEmpty else {
            diag.notice("selection could not be read length=\(range.length, privacy: .public)")
            runtime.feedback.report(.selectionUnreadable)
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
        // 開発版だけ、`defaults write org.sumibi.inputmethod.Sumibi PrototypePokeStyle -string <style>`で選ぶ。
        // marked(既定): 文書を変えない空の未確定文字列のみ。insert: 空文字の挿入のみ。both: 両方。off: 何もしない。
        let style = DevelopmentOptions.current.pokeStyle
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
        guard let request = state.pending, let readyAt = runtime.conversion.readyAt, Date() >= readyAt,
              let input = client() as (any IMKTextInput)?, !isExcluded(input),
              input.selectedRange().location != NSNotFound else { return }
        diag.notice("completing pending request on \(reason, privacy: .public) id=\(self.diagID, privacy: .public) request=\(request.id, privacy: .public)")
        finishRequest(NSNumber(value: request.id), using: input)
    }

    private func hideCandidatePanel() {
        candidateWindow.hide()
    }

    private func validatesPrevious(in input: IMKTextInput) -> Bool {
        guard let previous = state.previous else { return false }
        return runtime.replacement.validatesAnchor(in: ReplacementInput(input), expected: previous.result)
    }

    /// 入力先がSumibiの対象外のアプリか。仕様書の「3.5 対象外のアプリ」を参照する。
    ///
    /// Sumibi自身のAPI設定欄は対象外とする。未確定文字列のまま「設定を保存」を押すと、
    /// 確定が保存に間に合わず、入力値が空のまま保存されるため。
    /// ユーザー辞書の編集シートだけは日本語変換が必要なので、開いている間は許可する。
    private func isExcluded(_ client: Any?) -> Bool {
        let bundleID = (client as? IMKTextInput)?.bundleIdentifier()
        return ExcludedApplications.contains(bundleID)
            || (isOwnApplication(bundleID) && !runtime.isEditingUserDictionary)
    }

    private func isOwnApplication(_ bundleID: String?) -> Bool {
        guard let bundleID, let own = Bundle.main.bundleIdentifier else { return false }
        return bundleID.caseInsensitiveCompare(own) == .orderedSame
    }

    /// 対象外のアプリへ移ったとき、他のアプリで進めていた入力を、別アプリへの切り替えと同じく終える。
    /// 変換結果や待機中の文字を対象外のアプリへ書き込まない。
    private func leaveForExcludedApplication() {
        let active = state.pending != nil || !state.marked.isEmpty || state.previous != nil || runtime.candidates.shouldBeVisible
        guard active else { return }
        diag.notice("excluded application: ending the current input id=\(self.diagID, privacy: .public)")
        cancelForTargetChange()
    }

    private func cancelForTargetChange(rescueMarked: Bool = true) {
        runtime.cancelForTargetChange(rescueMarked: rescueMarked)
    }
}
