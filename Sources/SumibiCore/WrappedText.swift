import Foundation

/// ターミナルで動く全画面のアプリ(Claude Codeなど)が折り返して表示した文字列と、書き込んだ原文の照合。
///
/// Claude Codeは長い入力を単語の区切りで折り返し、区切りの空白を「改行と字下げの空白」に置き換えて表示する。
/// ターミナルが返す文字列にもその改行と字下げが入るため、原文と一文字ずつは一致しない。
public enum WrappedText {
    /// `text`の末尾が`source`を折り返して表示したものであれば、その末尾部分のUTF-16での長さを返す。
    ///
    /// 改行とそれに続く空白を折り返しとみなして読み飛ばす。折り返し位置の原文が空白なら、その空白も読み飛ばす。
    /// それ以外の食い違いがあればnilを返す。
    public static func suffixLength(of source: String, in text: String) -> Int? {
        let s = Array(source.unicodeScalars)
        let t = Array(text.unicodeScalars)
        var i = t.count
        var j = s.count
        while j > 0 {
            guard i > 0 else { return nil }
            if t[i - 1] == s[j - 1] {
                i -= 1
                j -= 1
                continue
            }
            var k = i
            while k > 0, t[k - 1] == " " { k -= 1 }
            guard k > 0, t[k - 1] == "\n" else { return nil }
            i = k - 1
            if s[j - 1] == " " { j -= 1 }
        }
        return t[i...].reduce(0) { $0 + $1.utf16.count }
    }
}
