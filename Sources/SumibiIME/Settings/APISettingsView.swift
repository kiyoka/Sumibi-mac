import SwiftUI
import SumibiCore

/// API設定の画面。項目名と流れはSumibi-iOSの「API設定」に合わせる。
struct APISettingsView: View {
    @State private var model = APISettingsModel(onConfigurationSaved: { InputRuntime.shared.ambient.settingsChanged() })
    @State private var userDictionary = ""
    @State private var isShowingUserDictionary = false
    @State private var isShowingDeletionConfirmation = false
    @State private var isShowingUsageResetConfirmation = false
    @State private var isShowingDecisionsSettings = false
    @State private var isShowingMozcLicense = false
    @State private var isShowingDiagnostics = false
    @FocusState private var focusedField: Field?

    private enum Field { case endpoint, modelName, apiKey }

    var body: some View {
        Form {
            Section {
                Picker("接続先", selection: Binding(
                    get: { model.provider },
                    set: {
                        focusedField = nil
                        model.selectProvider($0)
                    }
                )) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                if model.provider == .other {
                    TextField("APIのURL", text: $model.endpoint, prompt: Text("例：https://example.com/v1"))
                        .focused($focusedField, equals: .endpoint)
                } else {
                    LabeledContent("APIのURL") {
                        Text(model.endpoint)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                switch model.provider {
                case .openAI:
                    Picker("モデル", selection: $model.modelChoice) {
                        ForEach(ModelPreset.allCases) { preset in
                            Text("\(preset.displayName)（\(preset.summary)）").tag(ModelChoice.preset(preset))
                        }
                        Text("自由入力").tag(ModelChoice.custom)
                    }
                    if model.modelChoice == .custom {
                        TextField("モデル名", text: $model.customModelName, prompt: Text("例：gpt-6-sol"))
                            .focused($focusedField, equals: .modelName)
                            .accessibilityLabel("モデル名（自由入力）")
                    }
                case .google:
                    Picker("モデル", selection: $model.geminiModel) {
                        ForEach(GeminiModelOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                case .other:
                    TextField("モデル名", text: $model.customModelName, prompt: Text("例：gpt-6-sol"))
                        .focused($focusedField, equals: .modelName)
                        .accessibilityLabel("モデル名")
                }
                if model.showsAPIKeyEditor {
                    SecureField(model.hasStoredAPIKey ? "新しいAPIキー" : "APIキー", text: $model.apiKey,
                                prompt: Text("APIキーを入力"))
                        .focused($focusedField, equals: .apiKey)
                    if model.hasStoredAPIKey {
                        LabeledContent("現在のAPIキー") {
                            Text(model.storedAPIKeyDisplay ?? "未設定")
                                .monospaced()
                                .privacySensitive()
                                .lineLimit(1)
                        }
                        Button("APIキーの変更をキャンセル") {
                            model.cancelAPIKeyEditing()
                            focusedField = nil
                        }
                    }
                } else {
                    LabeledContent("APIキー（保存済み）") {
                        HStack {
                            Text(model.storedAPIKeyDisplay ?? "未設定")
                                .monospaced()
                                .privacySensitive()
                                .lineLimit(1)
                            Button("変更") {
                                model.beginAPIKeyEditing()
                                focusedField = .apiKey
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("API設定")
            } footer: {
                Text("接続先ごとのAPIのURL・モデル名はこのMacの設定に、APIキーは送信先ごとのKeychain項目へ保存します。保存済みキーを変更するときは「変更」を押して新しいキーを入力し、「設定を保存」を押してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("接続先：\(model.savedProviderDisplay)")
                Text("送信先：\(model.savedEndpointDisplay)")
                    .textSelection(.enabled)
                Toggle("この第三者AIへのデータ送信に同意する", isOn: Binding(
                    get: { model.hasConsent },
                    set: { model.setConsent($0) }
                ))
                Text("同意すると、変換のたびに変換対象の文字列と登録したユーザー辞書が上記の送信先へ送られます。送信先での扱いは、利用者が選んだAPIプロバイダー（OpenAI、Googleなど）の規約に従います。プロバイダーの料金が発生します。送信先を変えた場合は、改めて同意が必要です。同意はいつでも取り消せます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("手動変換時と、Decisions自動変換を有効にした場合の変換時に送信します。キー入力や原文をログへ保存しません。周辺文脈は送信しません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("送信先と料金")
            }

            Section {
                Button("Decisions自動変換の設定…") { isShowingDecisionsSettings = true }
                if !model.isDecisionsSupported {
                    Text(DecisionsError.unsupportedProvider.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("OpenAI Decisionsで日本語らしさを判定し、自動変換する機能です。公式OpenAI接続先と既存の変換用キーを使い、自動送信への同意を別途設定します（Googleや「その他」では使えません）。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    isShowingUserDictionary = true
                } label: {
                    HStack {
                        Label("ユーザー辞書", systemImage: "character.book.closed")
                        Spacer()
                        Text(dictionarySummary)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } footer: {
                Text("登録内容はすべての変換リクエストへ送信されます。変換対象などとの合計が1,000文字を超える要求は送信せず、エラーにします。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.usageStatistics.isEmpty {
                    Text("まだ変換の記録はありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.usageStatistics) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(item.provider.displayName) · \(item.model)")
                                .font(.headline)
                            LabeledContent("変換回数") {
                                Text("\(item.conversionCount.formatted(.number))回")
                                    .monospacedDigit()
                            }
                            LabeledContent("入力トークン") {
                                Text(item.inputTokens.formatted(.number))
                                    .monospacedDigit()
                            }
                            if item.cachedInputTokens > 0 {
                                LabeledContent("うちキャッシュ入力") {
                                    Text(item.cachedInputTokens.formatted(.number))
                                        .monospacedDigit()
                                }
                            }
                            LabeledContent("出力トークン") {
                                Text(item.outputTokens.formatted(.number))
                                    .monospacedDigit()
                            }
                            if item.unitemizedTokens > 0 {
                                LabeledContent("内訳不明トークン") {
                                    Text(item.unitemizedTokens.formatted(.number))
                                        .monospacedDigit()
                                }
                            }
                            LabeledContent("合計トークン") {
                                Text(item.totalTokens.formatted(.number))
                                    .monospacedDigit()
                            }
                            LabeledContent("概算費用（USD）") {
                                Text(model.estimatedCostDisplay(for: item))
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("利用状況をリセット", role: .destructive) {
                        isShowingUsageResetConfirmation = true
                    }
                }
            } header: {
                Text("利用状況")
            } footer: {
                Text("このMacで変換APIから返ったトークン数を接続先・モデル別に集計しています（Decisions自動変換の通信回数は「Decisions自動変換の設定」で確認できます）。概算費用はOpenAI（2026年10月時点）およびGoogle Gemini（2026年10月時点、Gemini 3.6 Flashは2026年12月31日UTCまで導入価格・2027年1月1日UTC以降は標準価格）の有料枠・Standard単価に基づく目安です。Google AI Studioの無料枠、各種割引、税金、為替、価格改定は反映されないため、実際の請求額は各プロバイダーの管理画面で確認してください。思考トークンなど単価の内訳が応答に含まれない場合は、概算費用を「不明」と表示します。原文や候補文字列は保存しません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("記号データ（Mozc）のライセンス…") { isShowingMozcLicense = true }
            }

            Section("診断") {
                Button("診断・デバッグ…") { isShowingDiagnostics = true }
                Text("変換や入力先の不具合を調べるための一時表示です。自動変換の有効化は不要です。原文を表示する場合は、診断画面で明示的にオンにしてください。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("設定を保存") {
                        focusedField = nil
                        model.save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasUnsavedChanges)

                    if model.hasStoredAPIKey {
                        Button("保存したAPIキーを削除", role: .destructive) {
                            isShowingDeletionConfirmation = true
                        }
                    }
                }
                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(model.statusIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 440)
        .onAppear {
            model.reload()
            userDictionary = SettingsStore().loadUserDictionary()
        }
        .sheet(isPresented: $isShowingUserDictionary) {
            UserDictionaryEditor(initialText: userDictionary) { saved in
                userDictionary = saved
            }
        }
        .sheet(isPresented: $isShowingDecisionsSettings) { DecisionsSettingsView() }
        .sheet(isPresented: $isShowingMozcLicense) { MozcLicenseView() }
        .sheet(isPresented: $isShowingDiagnostics) { DiagnosticsSettingsView() }
        .confirmationDialog("保存したAPIキーを削除しますか？",
                            isPresented: $isShowingDeletionConfirmation,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) { model.deleteAPIKey() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除すると元に戻せません。再度使うにはAPIキーの入力が必要です。")
        }
        .confirmationDialog("利用状況をリセットしますか？",
                            isPresented: $isShowingUsageResetConfirmation,
                            titleVisibility: .visible) {
            Button("リセット", role: .destructive) { model.resetUsageStatistics() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このMacに保存されている変換回数・トークン数・概算費用の記録を消去します。各プロバイダー側の請求額には影響しません。")
        }
    }

    private var dictionarySummary: String {
        let count = UserDictionary.validate(userDictionary).entries.count
        return count == 0 ? "未設定" : "\(count)件"
    }
}

/// 設定画面でのモデルの選び方。代表モデルのどれか、または自由入力。
enum ModelChoice: Hashable {
    case preset(ModelPreset)
    case custom
}

@Observable
final class APISettingsModel {
    var provider = AIProvider.openAI {
        didSet {
            guard !isUpdatingProviderInternally, provider != oldValue else { return }
            applyProviderSelection(from: oldValue, to: provider)
        }
    }
    var endpoint = ProviderConfiguration.defaultEndpoint {
        didSet {
            guard !isUpdatingEndpointInternally else { return }
            let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != loadedKeyEndpoint else { return }
            if apiKey.isEmpty {
                isEditingAPIKey = false
            }
            refreshStoredAPIKeyDisplay(for: trimmed)
        }
    }
    var modelChoice = ModelChoice.preset(.gpt6Sol)
    var geminiModel = GeminiModelOption.quality
    /// 自由入力を選んだときのモデル名。
    var customModelName = ""

    /// 保存・送信に使うモデル名。
    var modelName: String {
        switch provider {
        case .openAI:
            switch modelChoice {
            case .preset(let preset): preset.model
            case .custom: customModelName
            }
        case .google:
            geminiModel.rawValue
        case .other:
            customModelName
        }
    }
    var apiKey = ""
    private(set) var storedAPIKeyDisplay: String?
    private(set) var usageStatistics: [ModelUsageStatistics] = []
    private(set) var statusMessage = ""
    private(set) var statusIsError = false

    private var savedConfiguration = ProviderConfiguration()
    private var draftConfigurations: [AIProvider: ProviderConfiguration] = [:]
    private var loadedKeyEndpoint: String?
    private var isUpdatingProviderInternally = false
    private var isUpdatingEndpointInternally = false
    private let settings: SettingsStore
    private let keys: APIKeyStore
    private let onConfigurationSaved: () -> Void

    init(settings: SettingsStore = SettingsStore(), keys: APIKeyStore = APIKeyStore(),
         onConfigurationSaved: @escaping () -> Void = {}) {
        self.settings = settings
        self.keys = keys
        self.onConfigurationSaved = onConfigurationSaved
    }

    private(set) var hasConsent = false
    private(set) var isEditingAPIKey = false

    var hasStoredAPIKey: Bool { storedAPIKeyDisplay != nil }

    var showsAPIKeyEditor: Bool { !hasStoredAPIKey || isEditingAPIKey }

    var savedProviderDisplay: String { savedConfiguration.provider.displayName }

    var savedEndpointDisplay: String {
        savedConfiguration.endpoint.isEmpty ? "未設定" : savedConfiguration.endpoint
    }

    var isDecisionsSupported: Bool {
        savedConfiguration.provider == .openAI && DecisionsCoordinator.isOfficialOpenAI(savedConfiguration.endpoint)
    }

    func selectProvider(_ newProvider: AIProvider) {
        provider = newProvider
    }

    func beginAPIKeyEditing() {
        apiKey = ""
        isEditingAPIKey = true
    }

    func cancelAPIKeyEditing() {
        apiKey = ""
        isEditingAPIKey = false
    }

    func setConsent(_ isOn: Bool) {
        if isOn {
            let configuration = ProviderConfiguration(provider: provider, endpoint: endpoint, model: modelName)
            if let problem = configuration.problems().first(where: { $0 != .modelEmpty }) {
                report(problem.message, isError: true)
                return
            }
            guard !hasUnsavedEndpointChange else {
                report("同意の前に、変更したAPIのURLを保存してください。", isError: true)
                return
            }
            settings.saveConsent(for: savedConfiguration.endpoint)
            hasConsent = true
            report("AIへのデータ送信に同意しました。", isError: false)
        } else {
            settings.revokeConsent()
            hasConsent = false
            onConfigurationSaved()
            report("AIへのデータ送信の同意を取り消しました。", isError: false)
        }
    }

    private var hasUnsavedEndpointChange: Bool {
        provider != savedConfiguration.provider
            || endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != savedConfiguration.endpoint
    }

    var hasUnsavedChanges: Bool {
        !apiKey.isEmpty
            || provider != savedConfiguration.provider
            || endpoint != savedConfiguration.endpoint
            || modelName != savedConfiguration.model
    }

    func reload() {
        savedConfiguration = settings.loadProviderConfiguration()
        draftConfigurations = [:]
        setProviderInternally(savedConfiguration.provider)
        setEndpointInternally(savedConfiguration.endpoint)
        showModel(savedConfiguration.model, for: savedConfiguration.provider)
        hasConsent = settings.hasConsent(for: savedConfiguration.endpoint)
        usageStatistics = settings.loadUsageStatistics()
        apiKey = ""
        isEditingAPIKey = false
        reloadStoredAPIKeyDisplay(for: savedConfiguration.endpoint)
    }

    func save() {
        let configuration = ProviderConfiguration(provider: provider, endpoint: endpoint, model: modelName)
        if let problem = configuration.problems().first {
            report(problem.message, isError: true)
            return
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty, !APIKeyDisplay.isAcceptable(trimmedKey) {
            report("APIキーに空白や改行が含まれています。", isError: true)
            return
        }

        do {
            let normalized = configuration.normalized
            let previousEndpoint = savedConfiguration.endpoint
            let endpointChanged = normalized.endpoint != previousEndpoint
            if endpointChanged, !previousEndpoint.isEmpty {
                try? keys.migrateLegacyKey(for: previousEndpoint, settings: settings)
            }
            try settings.saveProviderConfiguration(normalized)
            savedConfiguration = normalized
            draftConfigurations[normalized.provider] = normalized
            if endpointChanged {
                // 送信先が変わったので、同意は取り直してもらう。
                settings.revokeConsent()
                hasConsent = false
            }
            setProviderInternally(normalized.provider)
            setEndpointInternally(normalized.endpoint)
            showModel(normalized.model, for: normalized.provider)

            if !trimmedKey.isEmpty {
                try keys.save(trimmedKey, for: normalized.endpoint)
                storedAPIKeyDisplay = APIKeyDisplay.masked(for: trimmedKey)
                loadedKeyEndpoint = normalized.endpoint
                apiKey = ""
                isEditingAPIKey = false
            } else if endpointChanged, loadedKeyEndpoint != normalized.endpoint {
                reloadStoredAPIKeyDisplay(for: normalized.endpoint)
            }
            onConfigurationSaved()
            if !hasStoredAPIKey {
                report("設定を保存しました。APIキーを入力すると変換できます。", isError: false)
            } else if !hasConsent {
                report("設定を保存しました。データ送信に同意すると変換できます。", isError: false)
            } else {
                report("設定を保存しました。", isError: false)
            }
        } catch {
            report("設定を保存できませんでした。", isError: true)
        }
    }

    private func applyProviderSelection(from oldProvider: AIProvider, to newProvider: AIProvider) {
        draftConfigurations[oldProvider] = ProviderConfiguration(
            provider: oldProvider,
            endpoint: endpoint,
            model: modelNameFor(provider: oldProvider)
        )
        if oldProvider == savedConfiguration.provider, !savedConfiguration.endpoint.isEmpty {
            try? keys.migrateLegacyKey(for: savedConfiguration.endpoint, settings: settings)
        }
        let target = draftConfigurations[newProvider] ?? settings.loadProviderConfiguration(for: newProvider)
        apiKey = ""
        isEditingAPIKey = false
        setEndpointInternally(target.endpoint)
        showModel(target.model, for: newProvider)
        hasConsent = target.endpoint == savedConfiguration.endpoint
            && settings.hasConsent(for: target.endpoint)
        refreshStoredAPIKeyDisplay(for: target.endpoint)
    }

    private func modelNameFor(provider targetProvider: AIProvider) -> String {
        switch targetProvider {
        case .openAI:
            switch modelChoice {
            case .preset(let preset): preset.model
            case .custom: customModelName
            }
        case .google:
            geminiModel.rawValue
        case .other:
            customModelName
        }
    }

    private func setProviderInternally(_ value: AIProvider) {
        isUpdatingProviderInternally = true
        defer { isUpdatingProviderInternally = false }
        provider = value
    }

    private func setEndpointInternally(_ value: String) {
        isUpdatingEndpointInternally = true
        defer { isUpdatingEndpointInternally = false }
        endpoint = value
    }

    /// 保存済みのモデル名が代表モデルならそれを選び、そうでなければ自由入力として文字列をそのまま出す。
    private func showModel(_ model: String, for provider: AIProvider) {
        switch provider {
        case .openAI:
            if let preset = ModelPreset(model: model) {
                modelChoice = .preset(preset)
                customModelName = ""
            } else {
                modelChoice = .custom
                customModelName = model
            }
        case .google:
            geminiModel = GeminiModelOption(rawValue: model) ?? .quality
        case .other:
            modelChoice = .custom
            customModelName = model
        }
    }

    private func refreshStoredAPIKeyDisplay(for candidateEndpoint: String) {
        let trimmed = candidateEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host() != nil else {
            loadedKeyEndpoint = trimmed
            storedAPIKeyDisplay = nil
            return
        }
        reloadStoredAPIKeyDisplay(for: trimmed)
    }

    private func reloadStoredAPIKeyDisplay(for targetEndpoint: String) {
        let trimmed = targetEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        loadedKeyEndpoint = trimmed
        guard !trimmed.isEmpty else {
            storedAPIKeyDisplay = nil
            return
        }
        do {
            storedAPIKeyDisplay = try keys.load(for: trimmed, settings: settings).flatMap { APIKeyDisplay.masked(for: $0) }
        } catch {
            storedAPIKeyDisplay = nil
            report("保存済みのAPIキーを読み出せませんでした。", isError: true)
        }
    }

    func deleteAPIKey() {
        do {
            try keys.delete(for: endpoint, settings: settings)
            apiKey = ""
            isEditingAPIKey = false
            storedAPIKeyDisplay = nil
            onConfigurationSaved()
            report("APIキーを削除しました。", isError: false)
        } catch {
            report("APIキーを削除できませんでした。", isError: true)
        }
    }

    func resetUsageStatistics() {
        settings.resetUsageStatistics()
        usageStatistics = settings.loadUsageStatistics()
        report("利用状況をリセットしました。", isError: false)
    }

    func estimatedCostDisplay(for item: ModelUsageStatistics) -> String {
        guard let cost = item.estimatedCostUSD else {
            return "不明"
        }
        if cost == 0 {
            return "$0.00"
        }
        if cost < 0.01 {
            return cost.formatted(
                .currency(code: "USD")
                    .locale(Locale(identifier: "en_US_POSIX"))
                    .precision(.fractionLength(4))
            )
        }
        return cost.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(2...4))
        )
    }

    private func report(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
