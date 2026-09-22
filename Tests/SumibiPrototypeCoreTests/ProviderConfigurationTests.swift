import XCTest
@testable import SumibiPrototypeCore

final class ProviderConfigurationTests: XCTestCase {
    func testNormalizedTrimsAndFallsBackToDefaults() {
        let configuration = ProviderConfiguration(endpoint: "  https://example.com  ", model: "   ")
        XCTAssertEqual(configuration.normalized.endpoint, "https://example.com")
        XCTAssertEqual(configuration.normalized.model, ProviderConfiguration.defaultModel)
    }

    func testDefaultConfigurationHasNoProblems() {
        XCTAssertEqual(ProviderConfiguration().problems(), [])
    }

    func testEmptyFieldsAreReported() {
        let configuration = ProviderConfiguration(endpoint: "  ", model: "")
        XCTAssertEqual(configuration.problems(), [.endpointEmpty, .modelEmpty])
    }

    func testHTTPIsRejectedForRemoteHostsButAllowedLocally() {
        XCTAssertEqual(ProviderConfiguration(endpoint: "http://api.example.com", model: "m").problems(),
                       [.endpointInsecure])
        XCTAssertEqual(ProviderConfiguration(endpoint: "http://localhost:11434", model: "m").problems(), [])
        XCTAssertEqual(ProviderConfiguration(endpoint: "http://127.0.0.1:1234", model: "m").problems(), [])
    }

    func testMalformedEndpointsAreReported() {
        XCTAssertEqual(ProviderConfiguration(endpoint: "api.openai.com", model: "m").problems(),
                       [.endpointNotAURL])
        XCTAssertEqual(ProviderConfiguration(endpoint: "https://", model: "m").problems(),
                       [.endpointNotAURL])
        XCTAssertEqual(ProviderConfiguration(endpoint: "ftp://example.com", model: "m").problems(),
                       [.endpointUnsupportedScheme("ftp")])
    }

    func testMaskedDisplayKeepsOnlyTheLastFourCharacters() {
        XCTAssertNil(APIKeyDisplay.masked(for: ""))
        XCTAssertEqual(APIKeyDisplay.masked(for: "abc"), "•••")
        XCTAssertEqual(APIKeyDisplay.masked(for: "sk-12345678"), "•••••••5678")
    }

    func testAPIKeyWithWhitespaceIsNotAcceptable() {
        XCTAssertTrue(APIKeyDisplay.isAcceptable("sk-abcdef"))
        XCTAssertFalse(APIKeyDisplay.isAcceptable(""))
        XCTAssertFalse(APIKeyDisplay.isAcceptable("sk-abc def"))
        XCTAssertFalse(APIKeyDisplay.isAcceptable("sk-abc\n"))
    }
}
