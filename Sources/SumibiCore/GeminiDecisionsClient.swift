import Foundation

/// Google Decisions REST is separate from Google's OpenAI-compatible conversion API.
public struct GeminiDecisionsClient: DecisionsService {
    public static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/decisions")!
    public static let model = "gemini-decision-1"
    private let key: String
    private let settings: DecisionsSettings
    private let session: URLSession

    public init(key: String, settings: DecisionsSettings = DecisionsSettings(), session: URLSession? = nil) {
        self.key = key
        self.settings = settings
        self.session = session ?? DecisionsTransport.session
    }

    private struct Payload: Encodable {
        struct Question: Encodable {
            let type = "noul"
            let instructions: String
        }
        let model: String
        let input: String
        let questions: [String: Question]
    }

    private struct Response: Decodable {
        struct Answer: Decodable {
            let type: String
            let noul: Double?
        }
        let answers: [String: Answer]
    }

    func makeBatchRequest(_ observations: [DecisionsObservation]) throws -> (URLRequest, [String]) {
        try DecisionsClient.validate(observations, settings: settings, key: key)
        let states = observations.enumerated().map { DecisionsClient.Evidence.State(id: "state_\($0.offset)", text: $0.element.text) }
        let names = states.map(\.id)
        let input = String(decoding: try JSONEncoder().encode(DecisionsClient.Evidence(states: states)), as: UTF8.self)
        let questions = Dictionary(uniqueKeysWithValues: names.map {
            ($0, Payload.Question(instructions: DecisionsClient.instructions(forState: $0)))
        })
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeout
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(model: Self.model, input: input, questions: questions))
        return (request, names)
    }

    public func score(_ observation: DecisionsObservation) async throws -> Double {
        guard case .probability(let value) = try await scores([observation])[0] else { throw DecisionsError.refused }
        return value
    }

    public func scores(_ observations: [DecisionsObservation]) async throws -> [DecisionsAnswer] {
        let (request, names) = try makeBatchRequest(observations)
        let data = try await DecisionsTransport.send(request, session: session, timeout: settings.timeout)
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              Set(response.answers.keys) == Set(names) else { throw DecisionsError.invalidResponse }
        return try names.map { name in
            guard let answer = response.answers[name], answer.type == "noul",
                  let value = answer.noul, (0.01...0.99).contains(value) else {
                throw DecisionsError.invalidResponse
            }
            return .probability(value)
        }
    }
}
