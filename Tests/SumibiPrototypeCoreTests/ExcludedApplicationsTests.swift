import XCTest
@testable import SumibiPrototypeCore

final class ExcludedApplicationsTests: XCTestCase {
    func testEmacsAndAquamacsAreExcluded() {
        XCTAssertTrue(ExcludedApplications.contains("org.gnu.Emacs"))
        XCTAssertTrue(ExcludedApplications.contains("org.gnu.Aquamacs"))
    }

    func testComparisonIgnoresCase() {
        XCTAssertTrue(ExcludedApplications.contains("org.gnu.emacs"))
    }

    func testTerminalsAndOtherAppsAreNotExcluded() {
        XCTAssertFalse(ExcludedApplications.contains("com.apple.Terminal"))
        XCTAssertFalse(ExcludedApplications.contains("com.mitchellh.ghostty"))
        XCTAssertFalse(ExcludedApplications.contains("com.apple.Notes"))
        // Emacs Lispのファイル形式の識別子など、似た名前を部分一致で拾わない。
        XCTAssertFalse(ExcludedApplications.contains("org.gnu.emacs-lisp"))
    }

    func testMissingIdentifierIsNotExcluded() {
        XCTAssertFalse(ExcludedApplications.contains(nil))
        XCTAssertFalse(ExcludedApplications.contains(""))
    }
}
