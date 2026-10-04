import XCTest
@testable import SumibiCore

final class WrappedTextTests: XCTestCase {
    func testExactSuffix() {
        XCTAssertEqual(WrappedText.suffixLength(of: "henkan dekimashita.", in: "───\n❯ henkan dekimashita."), 19)
    }

    func testSpaceReplacedByWrapAndIndent() {
        // 2026-09-27にClaude Codeの入力欄で記録した形。区切りの空白が「改行と2文字の字下げ」になる。
        let text = "───\n❯ nagaku nyuuryoku\n  shimasu . korede"
        XCTAssertEqual(WrappedText.suffixLength(of: "nagaku nyuuryoku shimasu . korede", in: text),
                       "nagaku nyuuryoku\n  shimasu . korede".utf16.count)
    }

    func testWrapInsideAWord() {
        XCTAssertEqual(WrappedText.suffixLength(of: "abcdef", in: "> abc\n  def"), "abc\n  def".utf16.count)
    }

    func testSeveralWraps() {
        let text = "❯ aa bb\n  cc dd\n  ee"
        XCTAssertEqual(WrappedText.suffixLength(of: "aa bb cc dd ee", in: text), "aa bb\n  cc dd\n  ee".utf16.count)
    }

    func testDifferentTextIsRejected() {
        XCTAssertNil(WrappedText.suffixLength(of: "henkan", in: "❯ hankan"))
        XCTAssertNil(WrappedText.suffixLength(of: "aa bb", in: "aa  bb"))
    }

    func testTextShorterThanSourceIsRejected() {
        XCTAssertNil(WrappedText.suffixLength(of: "shimasu", in: "masu"))
    }

    func testNonASCIIUsesUTF16Length() {
        XCTAssertEqual(WrappedText.suffixLength(of: "変換😀", in: "❯ 変換😀"), "変換😀".utf16.count)
    }
}
