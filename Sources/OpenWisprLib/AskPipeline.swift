import Foundation

/// Pro-tier ask pipeline (Stage C).
/// Sends the transcribed instruction, context text, and optional screen image to the Metered API Proxy.
final class AskPipeline {
    private let session: URLSession
    private let baseURL: URL
    let timeout: TimeInterval
    private let tokenProvider: () async -> String?

    // Ask calls use Vision and may take longer to process, hence a 90s timeout (per PRD)
    convenience init(timeout: TimeInterval = 90) {
        self.init(
            session: RewritePipeline.makeSession(configuration: .ephemeral, timeout: timeout),
            baseURL: RewritePipeline.proxyBaseURL,
            timeout: timeout,
            tokenProvider: { RewritePipeline.keychainToken() }
        )
    }

    init(
        session: URLSession,
        baseURL: URL,
        timeout: TimeInterval = 90,
        tokenProvider: @escaping () async -> String?
    ) {
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
        self.tokenProvider = tokenProvider
    }

    func ask(
        instruction: String,
        contextText: String?,
        contextTitle: String?,
        jpegData: Data?,
        uiTree: String?
    ) async -> Result<String, RewriteError> {
        guard let token = await tokenProvider() else { return .failure(.notAuthenticated) }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ask"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        let body = AskRequestBody(
            instruction: instruction,
            text: contextText,
            title: contextTitle,
            image: jpegData?.base64EncodedString(),
            uiTree: uiTree
        )
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            guard (200..<300).contains(http.statusCode) else {
                return RewritePipeline.interpret(status: http.statusCode, body: nil)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > RewritePipeline.maxResponseBytes { return .failure(.invalidResponse) }
            }
            return RewritePipeline.interpret(status: http.statusCode, body: data)
        } catch {
            return .failure(RewritePipeline.classify(networkError: error))
        }
    }
}

private struct AskRequestBody: Encodable {
    let instruction: String
    let text: String?
    let title: String?
    let image: String?
    let uiTree: String?
}
