import XCTest
import Security
import SumibiCore
@testable import SumibiIME

final class ConversionCoordinatorTests: XCTestCase {
    private var domains: [String] = []
    override func tearDown() {
        for name in domains { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        domains = []
        super.tearDown()
    }

    func testMissingKeyOrKeychainFailureNeverCreatesNetworkClient() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed] {
            let settings = settings()
            settings.saveConsent(for: ProviderConfiguration.defaultEndpoint)
            let keys = RecordingKeychain()
            keys.loadResult = (status, nil)
            let coordinator = ConversionCoordinator(settings: settings, keys: APIKeyStore(keychain: keys), responseMode: { "api" }) { _ in
                XCTFail("Client must not be created without a key")
                return ConstantConversionService()
            }
            XCTAssertThrowsError(try coordinator.service()) { XCTAssertEqual($0 as? ConversionError, .apiKeyMissing) }
        }
    }

    func testNoConsentOrChangedEndpointNeverCreatesNetworkClient() throws {
        let settings = settings()
        let keys = keychainWithFakeKey()
        let coordinator = ConversionCoordinator(settings: settings, keys: APIKeyStore(keychain: keys), responseMode: { "api" }) { _ in
            XCTFail("Client must not be created without matching consent")
            return ConstantConversionService()
        }
        XCTAssertThrowsError(try coordinator.service()) { XCTAssertEqual($0 as? ConversionError, .consentMissing) }
        settings.saveConsent(for: ProviderConfiguration.defaultEndpoint)
        try settings.saveProviderConfiguration(ProviderConfiguration(endpoint: "https://changed.invalid", model: "custom"))
        XCTAssertThrowsError(try coordinator.service()) { XCTAssertEqual($0 as? ConversionError, .consentMissing) }
    }

    func testMatchingConsentAndKeyUseStoredConfigurationWithFakeClient() async throws {
        let settings = settings()
        let configuration = ProviderConfiguration(endpoint: "https://example.invalid", model: "custom")
        try settings.saveProviderConfiguration(configuration)
        settings.saveConsent(for: configuration.endpoint)
        var received: OpenAICompatibleConfiguration?
        let coordinator = ConversionCoordinator(settings: settings, keys: APIKeyStore(keychain: keychainWithFakeKey()), responseMode: { "api" }) {
            received = $0
            return ConstantConversionService()
        }
        let result = await coordinator.convert(ConversionRequest(source: "abc"))
        XCTAssertEqual(result, .success(ConversionResult(candidates: ["固定結果"])))
        XCTAssertEqual(received?.endpoint.absoluteString, configuration.endpoint)
        XCTAssertEqual(received?.model, configuration.model)
        XCTAssertEqual(received?.apiKey, "fake-test-key")
    }

    func testOverLimitDoesNotEvenReadTheKeychain() async {
        let keys = RecordingKeychain()
        let coordinator = ConversionCoordinator(settings: settings(), keys: APIKeyStore(keychain: keys), responseMode: { "api" }) { _ in
            XCTFail("Over-limit requests must not create a client")
            return ConstantConversionService()
        }
        let result = await coordinator.convert(ConversionRequest(source: String(repeating: "a", count: 1001)))
        XCTAssertEqual(result, .failure(.overLimit(count: 1001, limit: 1000)))
        XCTAssertTrue(keys.calls.isEmpty)
    }

    func testSymbolsAreAddedOnlyAfterOneSuccessfulAlternativesRequestWithoutChangingPayload() async throws {
        let settings = settings()
        settings.saveConsent(for: ProviderConfiguration.defaultEndpoint)
        let service = SymbolRecordingService()
        let coordinator = ConversionCoordinator(settings: settings, keys: APIKeyStore(keychain: keychainWithFakeKey()),
            responseMode: { "api" }, dictionary: SupplementalCandidateDictionary(symbolTSV: "hoshi\t☆\t★")) { _ in service }
        let first = ConversionRequest(source: "hoshi", userDictionary: "user=辞書")
        let firstResult = await coordinator.convert(first)
        XCTAssertEqual(firstResult, .success(ConversionResult(candidates: ["星"])))
        let request = ConversionRequest(source: "hoshi", mode: .alternatives, currentConversion: "星", userDictionary: "user=辞書")
        let result = await coordinator.convert(request)
        XCTAssertEqual(result, .success(ConversionResult(candidates: ["星", "☆", "★"], dictionaryCandidates: ["☆", "★"])))
        let requests = await service.requests
        XCTAssertEqual(requests, [first, request]) // No extra request, no local index added to payload.
    }

    func testFailedAlternativesDoNotFallBackToLocalSymbols() async {
        let settings = settings()
        settings.saveConsent(for: ProviderConfiguration.defaultEndpoint)
        let service = SymbolRecordingService(fails: true)
        let coordinator = ConversionCoordinator(settings: settings, keys: APIKeyStore(keychain: keychainWithFakeKey()),
            responseMode: { "api" }, dictionary: SupplementalCandidateDictionary(symbolTSV: "hoshi\t☆\t★")) { _ in service }
        let result = await coordinator.convert(.init(source: "hoshi", mode: .alternatives))
        XCTAssertEqual(result, .failure(.offline))
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMissingSymbolResourceStillReturnsUnchangedLLMResponse() async {
        let settings = settings()
        settings.saveConsent(for: ProviderConfiguration.defaultEndpoint)
        let coordinator = ConversionCoordinator(settings: settings, keys: APIKeyStore(keychain: keychainWithFakeKey()),
            responseMode: { "api" }, dictionary: SupplementalCandidateDictionary()) { _ in SymbolRecordingService() }
        let result = await coordinator.convert(.init(source: "hoshi", mode: .alternatives))
        XCTAssertEqual(result, .success(ConversionResult(candidates: ["星"])))
    }

    private func settings() -> SettingsStore {
        let domain = "org.sumibi.tests.coordinator.\(UUID().uuidString)"
        domains.append(domain)
        return SettingsStore(defaults: UserDefaults(suiteName: domain)!, prototypeDefaults: { nil })
    }
    private func keychainWithFakeKey() -> RecordingKeychain {
        let keys = RecordingKeychain()
        keys.loadResult = (errSecSuccess, Data("fake-test-key".utf8) as CFData)
        return keys
    }
}

private struct ConstantConversionService: ConversionService {
    func convert(_ request: ConversionRequest) async throws -> ConversionResult { ConversionResult(candidates: ["固定結果"]) }
}

private actor SymbolRecordingService: ConversionService {
    private(set) var requests: [ConversionRequest] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        requests.append(request)
        if fails { throw ConversionError.offline }
        return ConversionResult(candidates: ["星"])
    }
}
