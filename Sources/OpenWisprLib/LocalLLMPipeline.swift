import Foundation

/// 100% Offline Local LLM Pipeline (Ollama / Local OpenAI compatible server).
/// Enables smart rewrites, edits, and screen/context Q&A locally on device
/// with 0 network calls off loopback and 0 cloud token dependencies.
public final class LocalLLMPipeline: Sendable {
    public static let defaultOllamaURL = URL(string: "http://127.0.0.1:11434")!
    public static let defaultModel = "llama3.2"

    /// The URL to actually use for the local LLM, or nil when `configured` is
    /// present but is not http(s) to a loopback host.
    ///
    /// `localLLMEnabled` is a bypass: every gate (`RewriteGate`, `EditGate`,
    /// `AskGate`) skips the paid-tier `hasToken()` check when it is on, on the
    /// premise that the request never leaves the device. A free-form
    /// `config.localLLMURL` string does not make that true by itself — this is
    /// the check that does, reusing `RewritePipeline.isLoopbackHost` (the same
    /// rule `OPENWISPR_PROXY_URL` is checked against) rather than a second copy
    /// of it. A caller that gets nil back must treat local LLM as OFF: fall back
    /// to the normal remote pipeline (which still requires a real token) rather
    /// than silently sending anything to the configured host.
    static func validatedURL(from configured: String?) -> URL? {
        guard let configured, !configured.isEmpty else { return defaultOllamaURL }
        guard let url = URL(string: configured),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "http" || scheme == "https",
              RewritePipeline.isLoopbackHost(host)
        else { return nil }
        return url
    }

    private let baseURL: URL
    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    public init(
        baseURL: URL = defaultOllamaURL,
        model: String = defaultModel,
        timeout: TimeInterval = 10,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    /// Rewrites raw transcript using local LLM with multilingual awareness.
    public func rewrite(transcript: String) async -> Result<String, RewriteError> {
        let prompt = """
        You are an intelligent multilingual voice dictation assistant.
        Your task is to take raw spoken speech transcriptions and convert them into clean, natural, and grammatically perfect text.

        Instructions:
        1. Fix speech-to-text phonetic errors, misheard words, and bad punctuation.
        2. Remove filler words (such as 'um', 'uh', 'like', 'you know').
        3. If the input is in a foreign language, translate and refine it into fluent, natural English if requested, or clean it up in its native language.
        4. Return ONLY the final polished output text with no markdown block, quotes, explanations, or conversational intro.

        Spoken input:
        \(transcript)
        """
        return await generate(prompt: prompt)
    }

    /// Edits selected text based on spoken instruction.
    public func edit(instruction: String, contextText: String, contextTitle: String?) async -> Result<String, RewriteError> {
        var contextInfo = ""
        if let contextTitle, !contextTitle.isEmpty {
            contextInfo = " (Active Window: \(contextTitle))"
        }
        let prompt = """
        Apply the following user instruction to edit the provided target text\(contextInfo). Return ONLY the edited replacement text with no explanation or conversational wrapper.

        User Instruction: \(instruction)

        Target Text:
        \(contextText)
        """
        return await generate(prompt: prompt)
    }

    /// Answers questions based on text or screen context.
    public func ask(instruction: String, contextText: String?, contextTitle: String?) async -> Result<String, RewriteError> {
        var contextBlock = ""
        if let contextText, !contextText.isEmpty {
            contextBlock = "\nContext:\n\(contextText)\n"
        }
        if let contextTitle, !contextTitle.isEmpty {
            contextBlock += "\nActive Window: \(contextTitle)\n"
        }
        let prompt = """
        Answer the following question concisely\(contextBlock).

        Question: \(instruction)
        """
        return await generate(prompt: prompt)
    }

    private func generate(prompt: String) async -> Result<String, RewriteError> {
        let endpoint = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let body = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false
        )

        guard let encoded = try? JSONEncoder().encode(body) else {
            return .failure(.invalidResponse)
        }
        request.httpBody = encoded

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.unavailable)
            }
            guard let decoded = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data) else {
                return .failure(.invalidResponse)
            }
            let text = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure(.invalidResponse)
            }
            return .success(text)
        } catch {
            if error is CancellationError { return .failure(.cancelled) }
            if let urlErr = error as? URLError, urlErr.code == .timedOut {
                return .failure(.timedOut)
            }
            return .failure(.offline)
        }
    }
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}
