/// Sumibiが動作しない入力先アプリ。仕様書の「3.5 対象外のアプリ」を参照する。
///
/// Emacsの中では、利用者はEmacs版のSumibiを使う。変換キーの`Control + J`もEmacsの`C-j`と重なる。
/// ターミナルの中で動くEmacsは入力先がターミナルとして見え、区別できないため含めない。
public enum ExcludedApplications {
    public static let bundleIdentifiers: Set<String> = [
        "org.gnu.Emacs",     // GNU Emacs。公式配布版・Homebrew・emacs-plus・Emacs Mac Portが共通で使う
        "org.gnu.Aquamacs",
    ]

    /// バンドル識別子は大文字小文字を区別せずに比べる。識別子が得られない入力先は対象外にしない。
    public static func contains(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return bundleIdentifiers.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }
}
