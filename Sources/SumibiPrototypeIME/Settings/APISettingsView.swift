import SwiftUI
import SumibiPrototypeCore

/// API設定の画面。項目名と流れはSumibi-iOSの「API設定」に合わせる。
struct APISettingsView: View {
    @State private var model = APISettingsModel()
    @State private var isShowingDeletionConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field { case endpoint, modelName, apiKey }

    var body: some View {
        Form {
            Section {
                TextField("APIのURL", text: $model.endpoint, prompt: Text("例：https://api.openai.com"))
                    .focused($focusedField, equals: .endpoint)
                TextField("モデル名", text: $model.modelName)
                    .focused($focusedField, equals: .modelName)
                SecureField(model.hasStoredAPIKey ? "APIキー（保存済み）" : "APIキー", text: $model.apiKey)
                    .focused($focusedField, equals: .apiKey)
                LabeledContent("保存済みAPIキー") {
                    Text(model.storedAPIKeyDisplay ?? "未設定")
                        .monospaced()
                        .privacySensitive()
                }
            } header: {
                Text("API設定")
            } footer: {
                Text("APIのURLとモデル名はこのMacの設定に、APIキーはKeychainへ保存します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("送信先：\(model.savedEndpointDisplay)")
                Toggle("この第三者AIへのデータ送信に同意する", isOn: Binding(
                    get: { model.hasConsent },
                    set: { model.setConsent($0) }
                ))
                Text("同意すると、変換のたびに変換対象の文字列が上記の送信先へ送られます。送信先での扱いは、利用者が選んだAPIプロバイダーの規約に従います。プロバイダーの料金が発生します。送信先を変えた場合は、改めて同意が必要です。同意はいつでも取り消せます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("変換キーを押したときだけ送信します。キー入力や原文をログへ保存しません。周辺文脈は送信しません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("送信先と料金")
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
        .onAppear { model.reload() }
        .confirmationDialog("保存したAPIキーを削除しますか？",
                            isPresented: $isShowingDeletionConfirmation,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) { model.deleteAPIKey() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除すると元に戻せません。再度使うにはAPIキーの入力が必要です。")
        }
    }
}

@Observable
final class APISettingsModel {
    var endpoint = ProviderConfiguration.defaultEndpoint
    var modelName = ProviderConfiguration.defaultModel
    var apiKey = ""
    private(set) var storedAPIKeyDisplay: String?
    private(set) var statusMessage = ""
    private(set) var statusIsError = false

    private var savedConfiguration = ProviderConfiguration()
    private let settings = SettingsStore()
    private let keys = APIKeyStore()

    private(set) var hasConsent = false

    var hasStoredAPIKey: Bool { storedAPIKeyDisplay != nil }

    var savedEndpointDisplay: String { savedConfiguration.endpoint }

    func setConsent(_ isOn: Bool) {
        if isOn {
            let configuration = ProviderConfiguration(endpoint: endpoint, model: modelName)
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
            report("AIへのデータ送信の同意を取り消しました。", isError: false)
        }
    }

    private var hasUnsavedEndpointChange: Bool {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != savedConfiguration.endpoint
    }

    var hasUnsavedChanges: Bool {
        !apiKey.isEmpty
            || endpoint != savedConfiguration.endpoint
            || modelName != savedConfiguration.model
    }

    func reload() {
        savedConfiguration = settings.loadProviderConfiguration()
        endpoint = savedConfiguration.endpoint
        modelName = savedConfiguration.model
        hasConsent = settings.hasConsent(for: savedConfiguration.endpoint)
        apiKey = ""
        do {
            storedAPIKeyDisplay = try keys.load().flatMap { APIKeyDisplay.masked(for: $0) }
        } catch {
            storedAPIKeyDisplay = nil
            report("保存済みのAPIキーを読み出せませんでした。", isError: true)
        }
    }

    func save() {
        let configuration = ProviderConfiguration(endpoint: endpoint, model: modelName)
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
            let endpointChanged = normalized.endpoint != savedConfiguration.endpoint
            try settings.saveProviderConfiguration(normalized)
            savedConfiguration = normalized
            if endpointChanged {
                // 送信先が変わったので、同意は取り直してもらう。
                settings.revokeConsent()
                hasConsent = false
            }
            endpoint = normalized.endpoint
            modelName = normalized.model

            if !trimmedKey.isEmpty {
                try keys.save(trimmedKey)
                storedAPIKeyDisplay = APIKeyDisplay.masked(for: trimmedKey)
                apiKey = ""
            }
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

    func deleteAPIKey() {
        do {
            try keys.delete()
            apiKey = ""
            storedAPIKeyDisplay = nil
            report("APIキーを削除しました。", isError: false)
        } catch {
            report("APIキーを削除できませんでした。", isError: true)
        }
    }

    private func report(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
