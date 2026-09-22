import XCTest
@testable import SumibiPrototypeCore

final class ConversionTests: XCTestCase {
    func testPayloadCountsSourceAndCurrentConversion() {
        let request = ConversionRequest(source: "ohayou", mode: .alternatives, currentConversion: "おはよう")
        XCTAssertEqual(request.payloadCharacterCount, 10)
        XCTAssertNoThrow(try ConversionLimit.check(request))
    }

    func testOverLimitIsRejectedBeforeSending() {
        let request = ConversionRequest(source: String(repeating: "a", count: 1_001))
        XCTAssertThrowsError(try ConversionLimit.check(request)) { error in
            XCTAssertEqual(error as? ConversionError, .overLimit(count: 1_001, limit: 1_000))
        }
        XCTAssertNoThrow(try ConversionLimit.check(ConversionRequest(source: String(repeating: "a", count: 1_000))))
    }

    func testFirstAndAlternativesUseDifferentInstructions() {
        let first = PromptBuilder.systemMessage(for: ConversionRequest(source: "ohayou"))
        let alternatives = PromptBuilder.systemMessage(
            for: ConversionRequest(source: "ohayou", mode: .alternatives, currentConversion: "おはよう")
        )
        XCTAssertTrue(first.contains("1件だけ"))
        XCTAssertTrue(alternatives.contains("最大12件"))
        XCTAssertTrue(PromptBuilder.userMessage(for: ConversionRequest(source: "ohayou")).contains("ohayou"))
    }

    func testDecoderAcceptsTheShapesModelsActuallyReturn() {
        XCTAssertEqual(CandidateDecoder.decode(#"{"candidates":["おはよう"]}"#), ["おはよう"])
        XCTAssertEqual(CandidateDecoder.decode("```json\n{\"candidates\":[\"おはよう\"]}\n```"), ["おはよう"])
        XCTAssertEqual(CandidateDecoder.decode(#"["おはよう","お早う"]"#), ["おはよう", "お早う"])
        XCTAssertEqual(CandidateDecoder.decode("おはよう"), ["おはよう"])
        XCTAssertEqual(CandidateDecoder.decode("   "), [])
    }

    func testNormalizeDropsEmptyAndDuplicateCandidates() {
        XCTAssertEqual(CandidateDecoder.normalize(["おはよう", " ", "おはよう", "お早う"], limit: 12),
                       ["おはよう", "お早う"])
        XCTAssertEqual(CandidateDecoder.normalize(["a", "b", "c"], limit: 2), ["a", "b"])
    }

    func testEndpointIsCompletedToChatCompletions() {
        func url(_ string: String) -> String? {
            URL(string: string).flatMap(OpenAICompatibleClient.chatCompletionsURL(from:))?.absoluteString
        }
        XCTAssertEqual(url("https://api.openai.com"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1/chat/completions"),
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("http://localhost:11434/v1"), "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(url("not a url"))
    }

    func testStatusCodesMapToDistinguishableErrors() {
        func error(_ code: Int) -> ConversionError? {
            do {
                try OpenAICompatibleClient.validate(statusCode: code)
                return nil
            } catch {
                return error as? ConversionError
            }
        }
        XCTAssertNil(error(200))
        XCTAssertEqual(error(401), .invalidCredentials)
        XCTAssertEqual(error(429), .rateLimited)
        XCTAssertEqual(error(503), .serverError(statusCode: 503))
        XCTAssertEqual(error(400), .httpError(statusCode: 400))
    }

    func testClientParsesASuccessfulResponse() async throws {
        let body = #"{"model":"gpt-test","choices":[{"message":{"role":"assistant","content":"{\"candidates\":[\"おはよう\"]}"}}]}"#
        let client = OpenAICompatibleClient(
            configuration: .init(endpoint: URL(string: "https://example.com")!, model: "m", apiKey: "k"),
            session: StubURLProtocol.session(status: 200, body: body)
        )
        let result = try await client.convert(ConversionRequest(source: "ohayou"))
        XCTAssertEqual(result.candidates, ["おはよう"])
        XCTAssertEqual(result.model, "gpt-test")
    }

    func testClientReportsCredentialProblems() async {
        let client = OpenAICompatibleClient(
            configuration: .init(endpoint: URL(string: "https://example.com")!, model: "m", apiKey: "k"),
            session: StubURLProtocol.session(status: 401, body: "{}")
        )
        do {
            _ = try await client.convert(ConversionRequest(source: "ohayou"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ConversionError, .invalidCredentials)
        }
    }

    func testClientRefusesToSendWithoutAnAPIKey() async {
        let client = OpenAICompatibleClient(
            configuration: .init(endpoint: URL(string: "https://example.com")!, model: "m", apiKey: ""),
            session: StubURLProtocol.session(status: 200, body: "{}")
        )
        do {
            _ = try await client.convert(ConversionRequest(source: "ohayou"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ConversionError, .apiKeyMissing)
        }
    }
}

/// 通信せずに決まった応答を返すスタブ。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "{}"

    static func session(status: Int, body: String) -> URLSession {
        Self.status = status
        Self.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
