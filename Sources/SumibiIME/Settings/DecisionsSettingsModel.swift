import Foundation
import Observation
import SumibiCore

/// Preferences only. Shares the existing OpenAI conversion key read-only;
/// key editing/deletion belongs to the parent API settings screen.
@Observable
final class DecisionsSettingsModel {
    var settings = DecisionsSettings()
    private(set) var storedKeyDisplay: String?
    private(set) var statusMessage = ""
    private(set) var statusIsError = false
    private var saved = DecisionsSettings()
    private let store: DecisionsSettingsStore
    private let manual: SettingsStore
    private let keys: APIKeyStore
    private let onChange: () -> Void

    init(store: DecisionsSettingsStore = DecisionsSettingsStore(), keys: APIKeyStore = APIKeyStore(),
         manualSettings: SettingsStore = SettingsStore(), onChange: @escaping () -> Void = {}) {
        self.store = store; self.keys = keys; self.manual = manualSettings; self.onChange = onChange
    }

    var hasStoredKey: Bool { storedKeyDisplay != nil }
    var callCount: Int { store.calls }

    func reload() {
        statusMessage = ""; statusIsError = false
        saved = store.load(); settings = saved; storedKeyDisplay = nil
        guard DecisionsCoordinator.isOfficialOpenAI(manual.loadProviderConfiguration().endpoint) else {
            report(DecisionsError.unsupportedProvider.message, error: true); return
        }
        do { storedKeyDisplay = try keys.load().flatMap { APIKeyDisplay.masked(for: $0) } }
        catch { report("OpenAI用APIキーを読み出せませんでした。親画面のキーとKeychainアクセスを確認してください。", error: true) }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            let provider = manual.loadProviderConfiguration()
            guard DecisionsCoordinator.isOfficialOpenAI(provider.endpoint) else {
                report(DecisionsError.unsupportedProvider.message, error: true); return
            }
            guard saved.consent, manual.hasConsent(for: provider.endpoint),
                  let key = try? keys.load(), APIKeyDisplay.isAcceptable(key) else {
                report("親画面でOpenAIキーと変換への送信同意を設定し、この画面でも自動送信に同意してください。", error: true); return
            }
        }
        persist { $0.enabled = enabled }
    }

    func setConsent(_ consent: Bool) {
        persist { $0.consent = consent; if !consent { $0.enabled = false } }
    }

    func adjustMaximumCalls(increasing: Bool) {
        let current = min(1_000_000, max(1, settings.maximumCalls))
        let value = increasing ? min(1_000_000, (current / 1_000 + 1) * 1_000)
            : max(1_000, ((current - 1) / 1_000) * 1_000)
        guard value != settings.maximumCalls else { return }
        persist { $0.maximumCalls = value }
    }

    func setThreshold(_ value: Double) {
        guard value.isFinite, (0...1).contains(value) else {
            report("判定閾値が正しくありません。", error: true); return
        }
        guard value != saved.threshold else { return }
        persist { $0.threshold = value }
    }

    private func persist(_ edit: (inout DecisionsSettings) -> Void) {
        var next = saved; edit(&next)
        do {
            try store.save(next); saved = next; settings = next; onChange()
            report(next.enabled ? "全アプリを対象にDecisions自動変換を有効にしました。" : "Decisions設定を保存しました。", error: false)
        } catch { report("Decisions設定を保存できませんでした。", error: true) }
    }

    func resetCalls() {
        store.touchRevision(); store.resetCalls(); onChange()
        report("費用の確認後、Decisionsの通信回数をリセットしました。旧Jevの回数・請求額は変更していません。", error: false)
    }

    private func report(_ message: String, error: Bool) { statusMessage = message; statusIsError = error }
}
