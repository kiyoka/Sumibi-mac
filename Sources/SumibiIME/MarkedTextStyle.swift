import AppKit

/// 未確定文字列に付ける控えめな下線。
///
/// 装飾のない文字列を渡すと、Chromeは未確定文字列に半透明の背景を重ね、範囲選択のように見せる。
/// 細い下線を明示すると背景が付かず、線だけになる。
/// 描画は入力先アプリが担当し、色はChrome・テキストエディット・メモのいずれでも使われなかった。
/// 色の指定は、反映するアプリのための控えめな既定値として残す。
enum MarkedTextStyle {
    /// 炭火の橙。入力先の外観(ライト・ダーク)はIMEから分からないため、どちらの背景でも見える明るさにする。
    private static let ember = NSColor(srgbRed: 0.91, green: 0.45, blue: 0.22, alpha: 0.75)

    static func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: ember
        ])
    }
}
