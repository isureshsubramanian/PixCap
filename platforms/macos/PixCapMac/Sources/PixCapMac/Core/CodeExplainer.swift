import Foundation

/// Explains a code snippet using a locally-running Ollama model.
///
/// Deliberately local-only. A hosted model would mean API keys, per-request
/// cost, and shipping the user's code to a third party — none of which fit a
/// tool whose selling point is that everything happens on your own machine.
/// If Ollama is not running, the feature reports that plainly rather than
/// silently degrading.
public enum CodeExplainer {

    /// Default Ollama endpoint. Configurable for a non-standard port.
    public static var endpoint: URL {
        let raw = Settings.string(SettingsKey.ollamaEndpoint, default: "http://localhost:11434")
        return URL(string: raw) ?? URL(string: "http://localhost:11434")!
    }

    public static var model: String {
        Settings.string(SettingsKey.ollamaModel, default: "llama3.2")
    }

    public enum ExplainError: LocalizedError {
        case unavailable
        case noModels
        case modelMissing(String, available: [String])
        case requestFailed(String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Ollama is not running. Start it, or install it from ollama.com, then try again."
            case .noModels:
                return "Ollama is running but has no models. Pull one first, e.g. `ollama pull llama3.2`."
            case .modelMissing(let wanted, let available):
                let list = available.prefix(4).joined(separator: ", ")
                return "Model '\(wanted)' is not installed. Available: \(list). Pull it with `ollama pull \(wanted)`."
            case .requestFailed(let reason):
                return "The model could not be reached: \(reason)"
            case .emptyResponse:
                return "The model returned nothing."
            }
        }
    }

    // MARK: - Availability

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    /// Models Ollama currently has, or nil when it is not reachable.
    public static func installedModels() async -> [String]? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            return nil
        }

        return tags.models.map(\.name)
    }

    public static func isAvailable() async -> Bool {
        await installedModels() != nil
    }

    // MARK: - Explaining

    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let options: Options

        struct Options: Encodable {
            let temperature: Double
            let num_predict: Int
        }
    }

    private struct GenerateResponse: Decodable {
        let response: String
    }

    /// Returns a plain-language explanation of `code`.
    public static func explain(code: String, language: String) async throws -> String {
        guard let models = await installedModels() else {
            throw ExplainError.unavailable
        }
        guard !models.isEmpty else {
            throw ExplainError.noModels
        }

        // Ollama tags carry a version suffix ("llama3.2:latest"), so match on
        // the base name rather than requiring an exact string.
        let wanted = model
        let resolved = models.first { $0 == wanted || $0.hasPrefix(wanted + ":") }
        guard let resolved else {
            throw ExplainError.modelMissing(wanted, available: models)
        }

        let prompt = """
            Explain what this \(language) code does, for a developer reading it for the first time.
            Be concise: a short summary, then the key steps. Do not repeat the code back.

            ```\(language)
            \(code)
            ```
            """

        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generation on a local model can be slow on first load.
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(GenerateRequest(
            model: resolved,
            prompt: prompt,
            stream: false,
            options: .init(temperature: 0.2, num_predict: 400)
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ExplainError.requestFailed(error.localizedDescription)
        }

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ExplainError.requestFailed(body.isEmpty ? "unexpected status" : body)
        }

        guard let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data) else {
            throw ExplainError.emptyResponse
        }

        let text = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExplainError.emptyResponse }
        return text
    }
}
