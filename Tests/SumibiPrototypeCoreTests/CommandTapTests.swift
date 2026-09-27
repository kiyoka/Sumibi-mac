import XCTest
@testable import SumibiPrototypeCore

final class CommandTapTests: XCTestCase {
    func testShortPressAloneIsTap() {
        XCTAssertTrue(CommandTap.isTap(duration: 0.12, onlyCommand: true, otherInput: false))
    }

    func testShortcutIsNotTap() {
        // 右Command + C のように、押している間に他のキーが押された。
        XCTAssertFalse(CommandTap.isTap(duration: 0.15, onlyCommand: true, otherInput: true))
    }

    func testLongPressIsNotTap() {
        XCTAssertFalse(CommandTap.isTap(duration: CommandTap.maximumDuration + 0.01, onlyCommand: true, otherInput: false))
    }

    func testWithOtherModifierIsNotTap() {
        XCTAssertFalse(CommandTap.isTap(duration: 0.1, onlyCommand: false, otherInput: false))
    }
}
