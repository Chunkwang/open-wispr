import Foundation

public enum RewriteError: LocalizedError {
    case notAuthenticated
    case requestFailed(Int)
    case network(Error)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        case .requestFailed(let code): return "Rewrite request failed (\(code))."
        case .network(let error): return error.localizedDescription
        }
    }
}

/// Pro-tier rewrite pipeline (TRD Section 3.2 / Data Flow 2).
/// Sends transcript TEXT ONLY — never audio — to the Metered API Proxy,
/// which is the only path to the Claude API. No API key ever lives in this client.
///
/// Not yet wired into the dictation hotkey flow: the TRD leaves the
/// trigger UX (separate hotkey vs. auto-on-release) as an open question
/// to settle with real usage data, not a guess made here.
public final class RewritePipeline {
    /// Overridable via the OPENWISPR_PROXY_URL env var during development.
    /// TODO: point at the real Cloudflare Worker URL once the proxy is deployed.
    public static var proxyBaseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["OPENWISPR_PROXY_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://proxy.dictation-wip.workers.dev")!
    }()

    private static let authAccount = "session-token"

    public init() {}

    public func isConfigured() -> Bool {
        Keychain.get(account: RewritePipeline.authAccount) != nil
    }

    public func setSessionToken(_ token: String) {
        Keychain.set(token, account: RewritePipeline.authAccount)
    }

    public func signOut() {
        Keychain.delete(account: RewritePipeline.authAccount)
    }

    /// Callers should fall back to inserting the raw transcript on any
    /// error per Section 3.2's failure mode — never block the user's workflow.
    public func rewrite(transcript: String, completion: @escaping (Result<String, RewriteError>) -> Void) {
        guard let token = Keychain.get(account: RewritePipeline.authAccount) else {
            completion(.failure(.notAuthenticated))
            return
        }

        var request = URLRequest(url: RewritePipeline.proxyBaseURL.appendingPathComponent("v1/rewrite"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONEncoder().encode(RewriteRequestBody(transcript: transcript))

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.network(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.requestFailed(-1)))
                return
            }
            guard (200..<300).contains(http.statusCode), let data = data else {
                completion(.failure(.requestFailed(http.statusCode)))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RewriteResponseBody.self, from: data) else {
                completion(.failure(.requestFailed(http.statusCode)))
                return
            }
            completion(.success(decoded.rewritten))
        }
        task.resume()
    }
}

private struct RewriteRequestBody: Encodable {
    let transcript: String
}

private struct RewriteResponseBody: Decodable {
    let rewritten: String
}
