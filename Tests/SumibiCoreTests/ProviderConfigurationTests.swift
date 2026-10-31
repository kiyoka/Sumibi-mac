import XCTest
@testable import SumibiCore

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
        XCTAssertEqual(APIKeyDisplay.masked(for: "abc"), "****")
        XCTAssertEqual(APIKeyDisplay.masked(for: "1234"), "****")
        XCTAssertEqual(APIKeyDisplay.masked(for: "sk-12345678"), "****5678")
    }

    func testLongAPIKeyMaskIsFixedWidthAndNeverIncludesItsPrefix() {
        let key = "sk-" + String(repeating: "x", count: 200) + "AB12"
        XCTAssertEqual(APIKeyDisplay.masked(for: key), "****AB12")
        XCTAssertEqual(APIKeyDisplay.masked(for: key)?.count, 8)
    }

    func testAPIKeyWithWhitespaceIsNotAcceptable() {
        XCTAssertTrue(APIKeyDisplay.isAcceptable("sk-abcdef"))
        XCTAssertFalse(APIKeyDisplay.isAcceptable(""))
        XCTAssertFalse(APIKeyDisplay.isAcceptable("sk-abc def"))
        XCTAssertFalse(APIKeyDisplay.isAcceptable("sk-abc\n"))
    }

    func testProviderInferenceRecognizesOpenAIGoogleAndCustomEndpoints() {
        XCTAssertEqual(AIProvider.inferred(from: "https://api.openai.com"), .openAI)
        XCTAssertEqual(AIProvider.inferred(from: "https://api.openai.com/v1/chat/completions"), .openAI)
        XCTAssertEqual(AIProvider.inferred(from: "https://generativelanguage.googleapis.com/v1beta/openai"), .google)
        XCTAssertEqual(AIProvider.inferred(from: "https://generativelanguage.googleapis.com"), .google)
        XCTAssertEqual(AIProvider.inferred(from: "https://example.com/v1"), .other)
        XCTAssertEqual(AIProvider.inferred(from: ""), .openAI)
    }

    func testProviderDefaultEndpointsAndNormalizedResolution() {
        let openAI = ProviderConfiguration(provider: .openAI, endpoint: "  ", model: "  ")
        XCTAssertEqual(openAI.normalized, ProviderConfiguration(
            provider: .openAI,
            endpoint: "https://api.openai.com",
            model: "gpt-6-sol"
        ))

        let google = ProviderConfiguration(provider: .google, endpoint: " ", model: " ")
        XCTAssertEqual(google.normalized, ProviderConfiguration(
            provider: .google,
            endpoint: "https://generativelanguage.googleapis.com/v1beta/openai",
            model: "gemini-3.6-flash"
        ))

        let other = ProviderConfiguration(provider: .other, endpoint: " https://custom.example.com/v1 ", model: " my-model ")
        XCTAssertEqual(other.normalized, ProviderConfiguration(
            provider: .other,
            endpoint: "https://custom.example.com/v1",
            model: "my-model"
        ))
        XCTAssertEqual(ProviderConfiguration(provider: .other, endpoint: " ", model: " ").problems(),
                       [.endpointEmpty, .modelEmpty])
    }

    func testLegacyConfigurationJSONWithoutProviderFieldDecodesByInferringProvider() throws {
        let legacyOpenAI = #"{"endpoint":"https://api.openai.com","model":"gpt-6-sol"}"#.data(using: .utf8)!
        let decodedOpenAI = try JSONDecoder().decode(ProviderConfiguration.self, from: legacyOpenAI)
        XCTAssertEqual(decodedOpenAI.provider, .openAI)
        XCTAssertEqual(decodedOpenAI.endpoint, "https://api.openai.com")
        XCTAssertEqual(decodedOpenAI.model, "gpt-6-sol")

        let legacyCustom = #"{"endpoint":"https://proxy.example.com/v1","model":"custom-model"}"#.data(using: .utf8)!
        let decodedCustom = try JSONDecoder().decode(ProviderConfiguration.self, from: legacyCustom)
        XCTAssertEqual(decodedCustom.provider, .other)
        XCTAssertEqual(decodedCustom.endpoint, "https://proxy.example.com/v1")
        XCTAssertEqual(decodedCustom.model, "custom-model")
    }
}
