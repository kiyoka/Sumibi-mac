import XCTest
@testable import SumibiIME

/// Source-level wiring checks, not a claim that native SwiftUI layout was tested.
final class DiagnosticsSettingsTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/SumibiIME/Settings/\(file).swift"), encoding: .utf8)
    }

    func testTopLevelSettingsOpensDiagnosticsIndependentlyOfDecisions() throws {
        let top = try source("APISettingsView")
        XCTAssertTrue(top.contains("Button(\"診断・デバッグ…\") { isShowingDiagnostics = true }"))
        XCTAssertTrue(top.contains(".sheet(isPresented: $isShowingDiagnostics) { DiagnosticsSettingsView() }"))
        XCTAssertFalse(try source("DecisionsSettingsView").contains("一時デバッグ"))
        XCTAssertFalse(try source("DecisionsSettingsView").contains("setDebugTextEnabled"))
    }

    func testMovedViewKeepsExistingReportsAndMemoryOnlyToggleWithoutProviderAccess() throws {
        let diagnostic = try source("DiagnosticsSettingsView")
        for marker in ["lastObservationText", "lastCommitText", "lastResultText", "setDebugTextEnabled",
                       "privacySensitive", "ログ・設定・ファイルには保存しません", "再起動後はオフ"] {
            XCTAssertTrue(diagnostic.contains(marker), marker)
        }
        for forbidden in ["APIKeyStore", "SettingsStore", "keys.load", "hasConsent", "URLSession", "attributedSubstring", "insertText"] {
            XCTAssertFalse(diagnostic.contains(forbidden), forbidden)
        }
        XCTAssertTrue(diagnostic.contains(".onAppear { runtime.ambient.stop() }"))
    }
}
