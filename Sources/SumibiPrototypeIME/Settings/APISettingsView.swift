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
                Text("変換のたびに、変換対象の文字列が上記のURLへ送信されます。送信先での扱いは、利用者が選んだAPIプロバイダーの規約に従います。プロバイダーの料金が発生します。")
                Text("APIキーを設定するまで、変換は行わず送信もしません。")
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

    var hasStoredAPIKey: Bool { storedAPIKeyDisplay != nil }

    var hasUnsavedChanges: Bool {
        !apiKey.isEmpty
            || endpoint != savedConfiguration.endpoint
            || modelName != savedConfiguration.model
    }

    func reload() {
        savedConfiguration = settings.loadProviderConfiguration()
        endpoint = savedConfiguration.endpoint
        modelName = savedConfiguration.model
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
            try settings.saveProviderConfiguration(normalized)
            savedConfiguration = normalized
            endpoint = normalized.endpoint
            modelName = normalized.model

            if !trimmedKey.isEmpty {
                try keys.save(trimmedKey)
                storedAPIKeyDisplay = APIKeyDisplay.masked(for: trimmedKey)
                apiKey = ""
            }
            report(hasStoredAPIKey ? "設定を保存しました。" : "設定を保存しました。APIキーを入力すると変換できます。",
                   isError: false)
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
