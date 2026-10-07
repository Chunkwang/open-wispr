import Foundation

/// Pro-tier edit pipeline.
/// Sends the transcribed instruction and context text to the Metered API Proxy.
final class EditPipeline {
    private let session: URLSession
    private let baseURL: URL
    let timeout: TimeInterval
    private let tokenProvider: () async -> String?

    convenience init(timeout: TimeInterval = 6) {
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
        timeout: TimeInterval = 6,
        tokenProvider: @escaping () async -> String?
    ) {
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
        self.tokenProvider = tokenProvider
    }

    func edit(instruction: String, contextText: String, contextTitle: String?) async -> Result<String, RewriteError> {
        guard let token = await tokenProvider() else { return .failure(.notAuthenticated) }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/edit"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        let body = EditRequestBody(
            instruction: instruction,
            text: contextText,
            title: contextTitle
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

private struct EditRequestBody: Encodable {
    let instruction: String
    let text: String
    let title: String?
}
