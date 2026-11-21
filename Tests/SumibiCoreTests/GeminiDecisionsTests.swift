import XCTest
@testable import SumibiCore

final class GeminiDecisionsTests: XCTestCase {
    private let observations = ["ni", "nihongo"].map { DecisionsObservation(text: $0, latestKey: "o")! }

    func testBatchUsesFixedGoogleDestinationAndNamedNoulQuestions() throws {
        let client = GeminiDecisionsClient(key: "fake-google-key")
        let (request, names) = try client.makeBatchRequest(observations)
        XCTAssertEqual(names, ["state_0", "state_1"])
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/decisions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fake-google-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gemini-decision-1")
        let questions = try XCTUnwrap(json["questions"] as? [String: [String: String]])
        XCTAssertEqual(Set(questions.keys), Set(names))
        for name in names {
            XCTAssertEqual(questions[name]?["type"], "noul")
            XCTAssertTrue(questions[name]?["instructions"]?.contains("state with id \(name)") == true)
        }
        let input = try XCTUnwrap((json["input"] as? String)?.data(using: .utf8))
        let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: [[String: String]]])
        XCTAssertEqual(evidence["states"]?.compactMap { $0["text"] }, observations.map(\.text))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fake-google-key"))
        XCTAssertNoThrow(try client.makeBatchRequest(Array(repeating: observations[0], count: 32)))
        XCTAssertThrowsError(try client.makeBatchRequest(Array(repeating: observations[0], count: 33)))
        XCTAssertThrowsError(try GeminiDecisionsClient(key: " ").makeBatchRequest(observations))
    }

    func testAnswersUseNoulInObservationOrderNotConfidence() async throws {
        let session = StubURLProtocol.session(status: 200, body: """
        {"answers":{"state_1":{"type":"noul","noul":0.99,"confidence":0.01},
                    "state_0":{"type":"noul","noul":0.01,"confidence":0.99}}}
        """)
        defer { session.invalidateAndCancel() }
        let answers = try await GeminiDecisionsClient(key: "fake", session: session).scores(observations)
        XCTAssertEqual(answers, [.probability(0.01), .probability(0.99)])
    }

    func testMissingUnknownAndInvalidAnswersFailClosed() async {
        let bodies = [
            "{}",
            #"{"answers":{"unknown":{"type":"noul","noul":0.95}}}"#,
            #"{"answers":{"state_0":{"type":"predicate","noul":0.95}}}"#,
            #"{"answers":{"state_0":{"type":"noul","confidence":0.95}}}"#,
            #"{"answers":{"state_0":{"type":"noul","noul":1}}}"#,
            #"{"answers":{"state_0":{"type":"noul","noul":"0.95"}}}"#
        ]
        for body in bodies {
            let session = StubURLProtocol.session(status: 200, body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await GeminiDecisionsClient(key: "fake", session: session).score(observations[0])
                XCTFail("Invalid Google response accepted")
            } catch { XCTAssertEqual(error as? DecisionsError, .invalidResponse) }
        }
    }

    func testTransportErrorDoesNotProduceAScore() async {
        let session = StubURLProtocol.session(status: 429, body: "{}")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GeminiDecisionsClient(key: "fake", session: session).score(observations[0])
            XCTFail("Rate-limited response accepted")
        } catch { XCTAssertEqual(error as? DecisionsError, .rateLimited) }
    }
}
