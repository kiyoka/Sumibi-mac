import XCTest
@testable import SumibiPrototypeCore

final class ModelPresetTests: XCTestCase {
    func testDefaultModelIsGPT6Sol() {
        XCTAssertEqual(ProviderConfiguration.defaultModel, "gpt-6-sol")
        XCTAssertEqual(ProviderConfiguration().model, "gpt-6-sol")
    }

    func testPresetsAreListedWithTheDefaultFirst() {
        XCTAssertEqual(ModelPreset.allCases.map(\.model), ["gpt-6-sol", "gpt-6-luna", "gpt-5.6-terra"])
    }

    func testPresetIsFoundOnlyForItsExactModelName() {
        XCTAssertEqual(ModelPreset(model: "gpt-6-luna"), .gpt6Luna)
        XCTAssertEqual(ModelPreset(model: " gpt-6-sol "), .gpt6Sol)
        XCTAssertNil(ModelPreset(model: "gpt-6-sol-2026-09-01"))
        XCTAssertNil(ModelPreset(model: "llama3"))
    }

    func testLegacyDefaultIsMigratedOnlyOnce() {
        let legacy = ProviderConfiguration(endpoint: "https://example.com", model: "gpt-5.6-terra")
        XCTAssertEqual(legacy.migratingLegacyDefaultModel(alreadyMigrated: false),
                       ProviderConfiguration(endpoint: "https://example.com", model: "gpt-6-sol"))
        XCTAssertEqual(legacy.migratingLegacyDefaultModel(alreadyMigrated: true), legacy)
    }

    func testOtherModelsAreNotMigrated() {
        for model in ["gpt-6-luna", "gpt-6-sol", "my-local-model"] {
            let configuration = ProviderConfiguration(model: model)
            XCTAssertEqual(configuration.migratingLegacyDefaultModel(alreadyMigrated: false), configuration)
        }
    }

    func testRequestBodyCarriesPresetSettings() throws {
        XCTAssertEqual(try body(model: "gpt-6-sol")["reasoning_effort"] as? String, "none")
        XCTAssertEqual(try body(model: "gpt-6-sol")["verbosity"] as? String, "low")
        XCTAssertEqual(try body(model: "gpt-6-luna")["verbosity"] as? String, "low")
        XCTAssertEqual(try body(model: "gpt-5.6-terra")["reasoning_effort"] as? String, "none")
        XCTAssertNil(try body(model: "gpt-5.6-terra")["verbosity"])
    }

    func testRequestBodyForCustomModelHasNoPresetSettings() throws {
        let json = try body(model: "my-local-model")
        XCTAssertEqual(json["model"] as? String, "my-local-model")
        XCTAssertNil(json["reasoning_effort"])
        XCTAssertNil(json["verbosity"])
    }

    private func body(model: String) throws -> [String: Any] {
        let data = try OpenAICompatibleClient.requestBody(for: ConversionRequest(source: "ohayou"), model: model)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
