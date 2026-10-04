import AppKit
import SwiftUI
import SumibiCore

/// iOS版と同じ行形式・検証規則で編集するmacOS用の詳細画面。
struct UserDictionaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var errors: [UserDictionaryValidationError] = []
    @State private var isShowingDiscardConfirmation = false
    @State private var saveMessage = ""

    private let initialText: String
    private let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    private var nonemptyLineCount: Int {
        text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ユーザー辞書").font(.title2.bold())
                Spacer()
                Button("キャンセル") { cancel() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("1行につき「よみ = 変換後」")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: text) { _, _ in
                    errors = []
                    saveMessage = ""
                }
                .accessibilityLabel("ユーザー辞書の内容")

            HStack {
                Text("例：sumibi = Sumibi / tari-zu = タリーズ")
                Spacer()
                Text("\(nonemptyLineCount)/100件・\(text.count)/2,000文字")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors) { error in
                            Text(error.lineNumber.map { "\($0)行目：\(error.reason)" } ?? error.reason)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            if !saveMessage.isEmpty {
                Text(saveMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
        .onAppear { InputRuntime.shared.isEditingUserDictionary = true }
        .onDisappear { InputRuntime.shared.isEditingUserDictionary = false }
        .confirmationDialog("変更を破棄しますか？", isPresented: $isShowingDiscardConfirmation) {
            Button("破棄", role: .destructive) { dismiss() }
            Button("編集を続ける", role: .cancel) {}
        } message: {
            Text("保存していない変更があります。")
        }
    }

    private func cancel() {
        if text == initialText { dismiss() }
        else { isShowingDiscardConfirmation = true }
    }

    private func save() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
            saveMessage = "入力中の文字を確定してから保存してください。"
            return
        }
        let validation = UserDictionary.validate(text)
        guard validation.isValid else {
            errors = validation.errors
            return
        }
        SettingsStore().saveUserDictionary(text)
        onSave(text)
        dismiss()
    }
}
