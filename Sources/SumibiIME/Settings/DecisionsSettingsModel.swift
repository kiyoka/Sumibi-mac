import Foundation
import Observation
import SumibiCore

/// Decisions自動変換の設定モデル。
/// 現在の変換接続先と同じ判定先に対する同意・有効化を管理する。
@Observable
final class DecisionsSettingsModel {
    var settings = DecisionsSettings()
    var openAIKeyInput = ""
    private(set) var isEditingOpenAIKey = false
    private(set) var storedKeyDisplay: String?
    private(set) var conversionConfiguration = ProviderConfiguration()
    private(set) var conversionKeyDisplay: String?
    private(set) var hasConversionConsent = false
    private(set) var isSupportedProvider = true
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
    var showsOpenAIKeyEditor: Bool { conversionProvider == .openAI && (!hasStoredKey || isEditingOpenAIKey) }
    var hasConversionKey: Bool { conversionKeyDisplay != nil }
    var conversionProvider: AIProvider { conversionConfiguration.provider }
    var conversionProviderName: String { conversionConfiguration.provider.displayName }
    var conversionEndpointDisplay: String {
        conversionConfiguration.endpoint.isEmpty ? "未設定" : conversionConfiguration.endpoint
    }
    var conversionModelDisplay: String {
        conversionConfiguration.model.isEmpty ? "未設定" : conversionConfiguration.model
    }
    var conversionKeyStatusDisplay: String { conversionKeyDisplay ?? "未設定" }
    var callCount: Int { store.calls }
    var threshold: Double { settings.threshold(for: conversionProvider) }
    var thresholdRange: ClosedRange<Double> { conversionProvider == .google ? 0.01...0.99 : 0...1 }
    var decisionsName: String { conversionProvider == .google ? "Gemini Decisions API" : "OpenAI Decisions API" }
    var decisionsEndpoint: URL { conversionProvider == .google ? GeminiDecisionsClient.endpoint : DecisionsClient.endpoint }
    var decisionsModel: String { conversionProvider == .google ? GeminiDecisionsClient.model : settings.model }

    func reload() {
        statusMessage = ""; statusIsError = false
        openAIKeyInput = ""; isEditingOpenAIKey = false
        saved = store.load(); settings = saved
        storedKeyDisplay = nil; conversionKeyDisplay = nil
        let provider = manual.loadProviderConfiguration()
        conversionConfiguration = provider
        hasConversionConsent = manual.hasConsent(for: provider.endpoint)
        guard DecisionsCoordinator.isSupportedConversionProvider(provider) else {
            isSupportedProvider = false
            report(DecisionsError.unsupportedProvider.message, error: true); return
        }
        isSupportedProvider = true
        var resetForProviderChange = false
        if (saved.enabled || saved.consent) && !store.hasConsent(forConversionEndpoint: provider.endpoint) {
            var reset = saved
            reset.enabled = false
            reset.consent = false
            if (try? store.save(reset, conversionEndpoint: nil)) != nil {
                saved = reset
                settings = reset
                onChange()
                resetForProviderChange = true
            }
        }
        do {
            conversionKeyDisplay = try keys.load(for: provider.endpoint, settings: manual)
                .flatMap { APIKeyDisplay.masked(for: $0) }
            if provider.provider == .openAI {
                storedKeyDisplay = conversionKeyDisplay
            }
            if resetForProviderChange {
                report("変換の接続先が変更されたため、自動変換をオフにしました。内容を確認して再度同意してください。", error: false)
            }
        } catch {
            report("APIキーを読み出せませんでした。キー設定とKeychainアクセスを確認してください。", error: true)
        }
    }

    func beginOpenAIKeyEditing() {
        guard conversionProvider == .openAI else { return }
        openAIKeyInput = ""
        isEditingOpenAIKey = true
    }

    func cancelOpenAIKeyEditing() {
        openAIKeyInput = ""
        isEditingOpenAIKey = false
    }

    func saveOpenAIKey() {
        let provider = manual.loadProviderConfiguration()
        guard provider.provider == .openAI, DecisionsCoordinator.isSupportedConversionProvider(provider) else {
            report(DecisionsError.unsupportedProvider.message, error: true); return
        }
        let trimmed = openAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report("OpenAI用APIキーを入力してください。", error: true); return
        }
        guard APIKeyDisplay.isAcceptable(trimmed) else {
            report("APIキーに空白や改行が含まれています。", error: true); return
        }
        do {
            try keys.save(trimmed, for: provider.endpoint)
            let masked = APIKeyDisplay.masked(for: trimmed)
            storedKeyDisplay = masked
            if provider.provider == .openAI {
                conversionKeyDisplay = masked
            }
            openAIKeyInput = ""
            isEditingOpenAIKey = false
            store.touchRevision()
            onChange()
            report("OpenAI用APIキーを保存しました。", error: false)
        } catch {
            report("OpenAI用APIキーを保存できませんでした。", error: true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        let provider = manual.loadProviderConfiguration()
        if enabled {
            guard DecisionsCoordinator.isSupportedConversionProvider(provider) else {
                report(DecisionsError.unsupportedProvider.message, error: true); return
            }
            guard saved.consent, store.hasConsent(forConversionEndpoint: provider.endpoint),
                  manual.hasConsent(for: provider.endpoint),
                  provider.problems().isEmpty else {
                report(missingPrerequisiteMessage(for: provider.provider), error: true); return
            }
            guard let key = try? keys.load(for: provider.endpoint, settings: manual),
                  APIKeyDisplay.isAcceptable(key) else {
                report(missingPrerequisiteMessage(for: provider.provider), error: true); return
            }
        }
        persist(conversionEndpoint: saved.consent ? provider.endpoint : nil) { $0.enabled = enabled }
    }

    func setConsent(_ consent: Bool) {
        let provider = manual.loadProviderConfiguration()
        if consent {
            guard DecisionsCoordinator.isSupportedConversionProvider(provider) else {
                report(DecisionsError.unsupportedProvider.message, error: true); return
            }
        }
        // Never rebind a stale sheet's consent to a different provider.
        guard provider == conversionConfiguration else { reload(); return }
        persist(conversionEndpoint: consent ? provider.endpoint : nil, grantingConsent: consent) {
            $0.consent = consent
            if !consent { $0.enabled = false }
        }
    }

    private func missingPrerequisiteMessage(for provider: AIProvider) -> String {
        switch provider {
        case .openAI:
            "OpenAIキーと親画面での変換への送信同意を設定し、この画面でも自動送信に同意してください。"
        case .google:
            "親画面でGoogleキーと変換への送信同意を設定し、この画面でもGoogleへの自動送信に同意してください。"
        case .other:
            DecisionsError.unsupportedProvider.message
        }
    }

    func adjustMaximumCalls(increasing: Bool) {
        let current = min(1_000_000, max(1, settings.maximumCalls))
        let value = increasing ? min(1_000_000, (current / 1_000 + 1) * 1_000)
            : max(1_000, ((current - 1) / 1_000) * 1_000)
        guard value != settings.maximumCalls else { return }
        persist(conversionEndpoint: saved.consent ? conversionConfiguration.endpoint : nil) { $0.maximumCalls = value }
    }

    func setThreshold(_ value: Double) {
        guard value.isFinite, thresholdRange.contains(value) else {
            report("判定閾値が正しくありません。", error: true); return
        }
        guard value != threshold else { return }
        persist(conversionEndpoint: saved.consent ? conversionConfiguration.endpoint : nil) {
            if conversionProvider == .google { $0.geminiThreshold = value }
            else { $0.threshold = value }
        }
    }

    private func persist(conversionEndpoint: String? = nil, grantingConsent: Bool = false,
                         _ edit: (inout DecisionsSettings) -> Void) {
        guard store.load() == saved, manual.loadProviderConfiguration() == conversionConfiguration else {
            reload(); return
        }
        var next = saved; edit(&next)
        do {
            try store.save(next, conversionEndpoint: conversionEndpoint, grantingConsent: grantingConsent)
            saved = next; settings = next; onChange()
            report(next.enabled ? "全アプリを対象にDecisions自動変換を有効にしました。" : "Decisions設定を保存しました。", error: false)
        } catch { report("Decisions設定を保存できませんでした。", error: true) }
    }

    func resetCalls() {
        store.touchRevision(); store.resetCalls(); onChange()
        report("費用の確認後、Decisionsの通信回数をリセットしました。旧Jevの回数・請求額は変更していません。", error: false)
    }

    private func report(_ message: String, error: Bool) { statusMessage = message; statusIsError = error }
}
