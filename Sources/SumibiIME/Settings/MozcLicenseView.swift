import SwiftUI

/// Read-only access to the notices shipped with this app; no network or settings changes.
struct MozcLicenseView: View {
    @Environment(\.dismiss) private var dismiss

    private func notice(_ name: String, extension ext: String?) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Mozc"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "同梱ライセンスを読み取れませんでした。アプリのResources/Mozcフォルダーを確認してください。"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("記号データ（Mozc）のライセンス").font(.headline)
            ScrollView {
                Text(notice("ATTRIBUTION", extension: "txt") + "\n\n" + notice("LICENSE", extension: nil))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 650, height: 520)
    }
}
