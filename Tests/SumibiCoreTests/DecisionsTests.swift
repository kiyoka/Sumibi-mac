import XCTest
@testable import SumibiCore

final class DecisionsTests: XCTestCase {
    func testDefaultsNeverAuthorizeSending() throws {
        let settings = DecisionsSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.consent)
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(settings.threshold, 0.5)
        XCTAssertEqual(settings.timeout, 10)
        XCTAssertEqual(settings.maximumCharacters, 512)
        XCTAssertEqual(settings.maximumCalls, 10_000)
        XCTAssertEqual(settings.batchWindowMilliseconds, 200)
        XCTAssertEqual(settings.model, "gpt-6-luna")
        XCTAssertFalse(settings.permitsSending)
        XCTAssertEqual(try JSONDecoder().decode(DecisionsSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testGlobalEnableAndConsentAreBothRequired() {
        var settings = DecisionsSettings()
        settings.enabled = true
        XCTAssertFalse(settings.permitsSending)
        settings.consent = true
        XCTAssertTrue(settings.permitsSending)
        settings.threshold = .nan
        XCTAssertFalse(settings.permitsSending)
    }

    func testInvalidPreferencesFailClosed() {
        var settings = DecisionsSettings()
        for threshold in [-0.01, 1.01, Double.nan, .infinity] {
            settings.threshold = threshold
            XCTAssertFalse(settings.isValid)
        }
        settings = DecisionsSettings()
        settings.maximumCharacters = 513
        XCTAssertFalse(settings.isValid)
        settings.maximumCharacters = 0
        XCTAssertFalse(settings.isValid)
        settings = DecisionsSettings()
        settings.timeout = 0
        XCTAssertFalse(settings.isValid)
        settings.timeout = .infinity
        XCTAssertFalse(settings.isValid)
        settings = DecisionsSettings()
        settings.maximumCalls = 0
        XCTAssertFalse(settings.isValid)
        settings = DecisionsSettings()
        settings.model = " "
        XCTAssertFalse(settings.isValid)
    }

    func testObservationIsSingleLineBoundedAndDoesNotTruncate() {
        XCTAssertNotNil(DecisionsObservation(text: String(repeating: "a", count: 512), latestKey: " "))
        XCTAssertNil(DecisionsObservation(text: String(repeating: "a", count: 513), latestKey: " "))
        for text in ["", "123.4", "日本語のみ", "abc\nmore", "abc\rmore"] {
            XCTAssertNil(DecisionsObservation(text: text, latestKey: " "))
        }
        XCTAssertNotNil(DecisionsObservation(text: "nihongo", latestKey: "BACKSPACE"))
        XCTAssertNil(DecisionsObservation(text: "nihongo", latestKey: "unexpected-operation"))
        XCTAssertNil(DecisionsObservation(text: "hello!", latestKey: "!"))
        XCTAssertNil(DecisionsObservation(text: "hello！", latestKey: "！"))
    }

    func testFixedWindowSettingsAcceptZeroAndRejectInvalidBounds() {
        var settings = DecisionsSettings()
        for window in [0, 200, 1_000] { settings.batchWindowMilliseconds = window; XCTAssertTrue(settings.isValid) }
        for window in [-1, 1_001] { settings.batchWindowMilliseconds = window; XCTAssertFalse(settings.isValid) }
    }

    func testRequestMatchesReferenceProtocolWithoutOtherData() throws {
        let observation = try XCTUnwrap(DecisionsObservation(text: "watashiwa ", latestKey: " "))
        let request = try DecisionsClient(key: "fake-decisions-key").makeRequest(observation)
        XCTAssertEqual(request.url, URL(string: "https://api.openai.com/v1/decisions"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-decisions-key")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["input", "model", "questions"])
        XCTAssertEqual(root["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(root["input"] as? String, "watashiwa ")
        let questions = try XCTUnwrap(root["questions"] as? [[String: Any]])
        let question = try XCTUnwrap(questions.first)
        XCTAssertEqual(Set(question.keys), ["type", "name", "instructions"])
        XCTAssertEqual(question["name"] as? String, "convert_now")
        XCTAssertEqual(question["type"] as? String, "predicate")
        XCTAssertTrue((question["instructions"] as? String)?.contains("Do not judge whether now is a good time to convert") == true)
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("fake-decisions-key"))
    }

    func testResponseBoundariesAndMalformedScores() async throws {
        let observation = try XCTUnwrap(DecisionsObservation(text: "nihongo ", latestKey: " "))
        for score in ["0", "0.799", "0.8", "1"] {
            let session = StubURLProtocol.session(status: 200, body: "{\"answers\":[{\"name\":\"convert_now\",\"type\":\"predicate\",\"probability\":\(score)}]}")
            defer { session.invalidateAndCancel() }
            let value = try await DecisionsClient(key: "fake-key", session: session).score(observation)
            XCTAssertEqual(value, Double(score)!)
        }
        for body in ["{}", "invalid-json", "{\"answers\":{\"convert_now\":{\"noul\":0.9}}}"] +
            ["true", "\"0.8\"", "1.01", "-0.1", "null"].map({ "{\"answers\":[{\"name\":\"convert_now\",\"type\":\"predicate\",\"probability\":\($0)}]}" }) {
            let session = StubURLProtocol.session(status: 200, body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await DecisionsClient(key: "fake-key", session: session).score(observation)
                XCTFail("Malformed response was accepted")
            } catch { XCTAssertEqual(error as? DecisionsError, .invalidResponse) }
        }
    }

    func testBatchPayloadRetainsEveryStateWithIndependentNamedQuestions() throws {
        let observations = ["n", "ni", "nihongo "].map { DecisionsObservation(text: $0, latestKey: "o")! }
        let request = try DecisionsClient(key: "fake-key").makeBatchRequest(observations)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["model", "input", "questions"])
        let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap((root["input"] as? String)?.data(using: .utf8))) as? [String: Any])
        let states = try XCTUnwrap(evidence["states"] as? [[String: String]])
        XCTAssertEqual(states.map { $0["text"]! }, observations.map(\.text))
        XCTAssertEqual(states.map { $0["id"]! }, ["state_0", "state_1", "state_2"])
        let questions = try XCTUnwrap(root["questions"] as? [[String: String]])
        XCTAssertEqual(questions.map { $0["name"]! }, states.map { $0["id"]! })
        for question in questions {
            XCTAssertEqual(question["type"], "predicate")
            XCTAssertTrue(question["instructions"]!.contains("Ignore every other state"))
            XCTAssertTrue(question["instructions"]!.contains("state with id \(question["name"]!)"))
        }
        XCTAssertThrowsError(try DecisionsClient(key: "fake-key").makeBatchRequest([]))
        XCTAssertNoThrow(try DecisionsClient(key: "fake-key").makeBatchRequest(Array(repeating: observations[0], count: 32)))
        XCTAssertThrowsError(try DecisionsClient(key: "fake-key").makeBatchRequest(Array(repeating: observations[0], count: 33)))
    }

    func testBatchScoresMatchNamesRatherThanResponseOrderAndPreserveRefusals() async throws {
        let session = StubURLProtocol.session(status: 200, body: """
        {"answers":[{"name":"state_2","type":"refusal","refusal":"private response"},
        {"name":"state_1","type":"predicate","probability":0.8},
        {"name":"state_0","type":"predicate","probability":0.2}]}
        """)
        defer { session.invalidateAndCancel() }
        let values = try await DecisionsClient(key: "fake-key", session: session).scores(
            ["n", "ni", "nihongo"].map { DecisionsObservation(text: $0, latestKey: "o")! })
        XCTAssertEqual(values, [.probability(0.2), .probability(0.8), .refused])
    }

    func testMalformedBatchNeverMixesOrAcceptsMissingDuplicateOrRefusedPredicates() async throws {
        let observation = DecisionsObservation(text: "nihongo", latestKey: "o")!
        let valid = "{\"name\":\"state_0\",\"type\":\"predicate\",\"probability\":0.9}"
        for body in ["{\"answers\":[]}", "{\"answers\":[\(valid),\(valid)]}",
            "{\"answers\":[\(valid),{\"name\":\"unexpected\",\"type\":\"predicate\",\"probability\":0.8}]}",
            "{\"answers\":[\(valid),{\"name\":\"state_1\",\"type\":\"predicate\",\"probability\":true}]}",
            "{\"answers\":[\(valid),{\"name\":\"state_1\",\"type\":\"choice\",\"probability\":0.8}]}",
            "{\"answers\":[\(valid),{\"name\":\"state_1\",\"type\":\"predicate\",\"probability\":0.8,\"refusal\":\"secret\"}]}"] {
            let session = StubURLProtocol.session(status: 200, body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await DecisionsClient(key: "fake-key", session: session).scores([observation, observation])
                XCTFail("Invalid batch accepted")
            } catch { XCTAssertEqual(error as? DecisionsError, .invalidResponse) }
        }
    }

    func testSingleRefusalIsFixedErrorWithoutResponseText() async throws {
        let session = StubURLProtocol.session(status: 200, body: "{\"answers\":[{\"name\":\"convert_now\",\"type\":\"refusal\",\"refusal\":\"private response\"}]}")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await DecisionsClient(key: "fake-key", session: session).score(DecisionsObservation(text: "nihongo", latestKey: "o")!)
            XCTFail("Refusal accepted")
        } catch {
            XCTAssertEqual(error as? DecisionsError, .refused)
            XCTAssertFalse(DecisionsError.refused.message.contains("private response"))
        }
    }

    func testCancelledRequestCannotStartTransport() async throws {
        let session = StubURLProtocol.session(status: 200, body: "{}")
        defer { session.invalidateAndCancel() }
        let task = Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            return try await DecisionsClient(key: "fake-key", session: session).score(DecisionsObservation(text: "nihongo", latestKey: "o")!)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request ran") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testHTTPFailuresAreFixedCategories() async throws {
        let observation = try XCTUnwrap(DecisionsObservation(text: "nihongo ", latestKey: " "))
        for (status, expected) in [(401, DecisionsError.authentication), (403, .authentication), (429, .rateLimited),
                                   (500, .server), (400, .http), (302, .http)] {
            let session = StubURLProtocol.session(status: status, body: "private-key private-input private-error")
            defer { session.invalidateAndCancel() }
            do {
                _ = try await DecisionsClient(key: "fake-key", session: session).score(observation)
                XCTFail("HTTP failure was accepted")
            } catch { XCTAssertEqual(error as? DecisionsError, expected) }
        }
    }

    func testMissingKeyAndInvalidConfigurationFailBeforeTransport() throws {
        let observation = try XCTUnwrap(DecisionsObservation(text: "nihongo ", latestKey: " "))
        for key in ["", "  ", "bad\r\nheader"] {
            XCTAssertThrowsError(try DecisionsClient(key: key).makeRequest(observation)) {
                XCTAssertEqual($0 as? DecisionsError, .missingKey)
            }
        }
        var settings = DecisionsSettings()
        settings.threshold = .nan
        XCTAssertThrowsError(try DecisionsClient(key: "fake-key", settings: settings).makeRequest(observation)) {
            XCTAssertEqual($0 as? DecisionsError, .invalidSettings)
        }
    }

    func testTotalTimeoutCancelsSilentMockTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentDecisionsProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var settings = DecisionsSettings()
        settings.timeout = 0.02
        let observation = try XCTUnwrap(DecisionsObservation(text: "nihongo ", latestKey: " "))
        do {
            _ = try await DecisionsClient(key: "fake-key", settings: settings, session: session).score(observation)
            XCTFail("Silent transport must time out")
        } catch { XCTAssertEqual(error as? DecisionsError, .timedOut) }
    }

    func testAmbientEligibilityDoesNotCollectCodeDelimitersOrMultipleLines() {
        XCTAssertTrue(AmbientText.isEligible("watashiwa "))
        XCTAssertTrue(AmbientText.isEligible("don't know?"))
        for source in ["print(\"nihongo\")", "// comment", "# secret", "a\nb", "a\tb", "a@b", "a!"] {
            XCTAssertFalse(AmbientText.isEligible(source))
        }
    }

    func testAmbientRequestAndPunctuationDecorationDoNotDuplicateSuffixes() {
        for (source, suffix) in [("nihongo. ", "。"), ("nihongo,", "、"), ("nihongo？", "？")] {
            XCTAssertEqual(AmbientText.request(source: source, dictionary: "dummy"), ConversionRequest(source: "nihongo", userDictionary: "dummy"))
            let result = AmbientText.decorate(ConversionResult(candidates: ["日本語.。？ "]), source: source)
            XCTAssertEqual(result.candidates, ["日本語" + suffix])
        }
        XCTAssertEqual(AmbientText.decorate(ConversionResult(candidates: [" 日本語 "]), source: "nihongo ").candidates, ["日本語"])
        XCTAssertTrue(AmbientText.decorate(ConversionResult(candidates: [" \n "]), source: "nihongo.").candidates.isEmpty)
    }
}

private final class SilentDecisionsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
