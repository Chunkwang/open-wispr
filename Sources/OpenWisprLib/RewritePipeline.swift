import Foundation

/// Why a rewrite did not produce text. Every case means "insert the raw
/// transcript instead": the caller never blocks dictation on a rewrite
/// (TRD Section 3.2). The cases stay distinct because the app reacts to them
/// differently: sign-in prompt, upgrade prompt, plain notice.
///
/// `errorDescription` is diagnostic text for logs. User-facing wording is chosen
/// at the call site from the brand voice guide.
public enum RewriteError: LocalizedError, Equatable, Sendable {
    /// No session token stored; nothing was sent.
    case notAuthenticated
    /// 401: the token was rejected (expired or revoked).
    case unauthorized
    /// 402: the account is not on the Pro tier.
    case requiresPro
    /// 429: per-minute or monthly quota reached.
    case rateLimited
    /// 413: the transcript exceeds the server's size limit.
    case tooLong
    /// The device has no network connection.
    case offline
    /// The request did not finish in time. The deadline is total, not idle time.
    case timedOut
    /// The caller cancelled (for example a new recording started). Not a service
    /// problem: show no notice.
    case cancelled
    /// The service could not be reached for any other network reason.
    case unreachable
    /// 5xx from the service.
    case unavailable
    /// Any other unexpected HTTP status.
    case unexpectedStatus(Int)
    /// A success status with a body we cannot use (bad JSON or empty text).
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        case .unauthorized: return "Session rejected (401)."
        case .requiresPro: return "Rewrite requires the Pro tier (402)."
        case .rateLimited: return "Rewrite quota reached (429)."
        case .tooLong: return "Transcript too long (413)."
        case .offline: return "No network connection."
        case .timedOut: return "Rewrite request timed out."
        case .cancelled: return "Rewrite cancelled."
        case .unreachable: return "Rewrite service unreachable."
        case .unavailable: return "Rewrite service unavailable (5xx)."
        case .unexpectedStatus(let code): return "Unexpected response (\(code))."
        case .invalidResponse: return "Unusable response from rewrite service."
        }
    }
}

/// Pro-tier rewrite pipeline (TRD Section 3.2 / Data Flow 2).
/// Sends transcript TEXT ONLY, never audio, to the Metered API Proxy,
/// which is the only path to the Claude API. No API key ever lives in this client.
///
/// Runs automatically after each dictation, but only when `RewriteGate` allows it
/// (rewrite mode on, consent recorded, signed in); see `RewriteCoordinator`.
///
/// Internal on purpose: `RewriteCoordinator` is the only place that constructs
/// one (a test scans the sources), so nothing can send a transcript without
/// passing the gate.
final class RewritePipeline {
    /// `.invalid` is reserved (RFC 2606) and never resolves, so until the Worker
    /// is deployed (Task 2.10/2.11) a build can't send anything to a hostname
    /// someone else could register. Replace with the real URL then.
    static let defaultProxyURL = URL(string: "https://proxy.invalid")!

    /// The OPENWISPR_PROXY_URL override exists for local development only and is
    /// honoured in DEBUG builds. In a release build anything that could set the
    /// environment (launchd, a LaunchAgent, a tampered Info.plist) could otherwise
    /// send the session token and transcripts to a host of its choosing.
    static let proxyBaseURL: URL = {
        #if DEBUG
        let allowOverride = true
        #else
        let allowOverride = false
        #endif
        return resolveBaseURL(
            override: ProcessInfo.processInfo.environment["OPENWISPR_PROXY_URL"],
            allowOverride: allowOverride
        )
    }()

    /// https only, except plain http to a loopback host for `wrangler dev`.
    /// Anything else, or a disallowed override, falls back to `defaultURL`.
    /// Shared with `AuthConfig`, which passes its own default.
    static func resolveBaseURL(override: String?, allowOverride: Bool, default defaultURL: URL = defaultProxyURL) -> URL {
        guard allowOverride,
              let override = override,
              let url = URL(string: override),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return defaultURL }
        if scheme == "https" || (scheme == "http" && isLoopbackHost(host)) { return url }
        return defaultURL
    }

    /// The loopback hostnames a plain-http override may target. Shared with
    /// `LocalLLMPipeline`, which must never let a configured URL reach a network
    /// host under a check that is meant to mean "stays on this machine".
    static func isLoopbackHost(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    private let session: URLSession
    private let baseURL: URL
    let timeout: TimeInterval
    private let tokenProvider: () async -> String?

    /// Production configuration: Keychain token, default proxy URL, and an
    /// ephemeral session so transcripts are never written to a URL cache or cookie
    /// store. `timeout` is a hard total deadline for the whole request.
    convenience init(timeout: TimeInterval = 6) {
        self.init(
            session: RewritePipeline.makeSession(configuration: .ephemeral, timeout: timeout),
            baseURL: RewritePipeline.proxyBaseURL,
            timeout: timeout,
            tokenProvider: { await RewritePipeline.refreshingKeychainToken() }
        )
    }

    /// `tokenProvider` and `session` are injectable so tests never touch the real
    /// Keychain or network. The token source is async because Stage 3 refreshes an
    /// expiring token before each call.
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

    /// Session that never follows redirects (a 3xx from a misconfigured or
    /// compromised host must not carry the token and transcript onward), keeps
    /// no cookies or cache, and enforces `timeout` as a total deadline: the request
    /// timeout is idle time only, so the resource timeout is what caps a slow trickle.
    /// `configuration` is a parameter so tests can add a stub protocol.
    static func makeSession(configuration: URLSessionConfiguration, timeout: TimeInterval = 6) -> URLSession {
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// The stored session's access token, as is (refresh arrives in Stage 3). Nil
    /// when signed out or when the Keychain cannot be read right now; both mean
    /// nothing is sent.
    static func keychainToken(store: SessionStore = SessionStore()) -> String? {
        guard case .success(let session?) = store.load() else { return nil }
        return session.accessToken
    }

    /// The stored session's access token, refreshing first (Task 3.5) when
    /// `AuthSession.needsRefresh` says it is expired or within its 60 s leeway.
    /// This is what the production `tokenProvider` above actually calls; plain
    /// `keychainToken` stays as the no-refresh primitive it always was.
    ///
    /// - A refresh that succeeds saves the WHOLE new session before returning its
    ///   access token: Supabase rotates the refresh token on every use, so
    ///   keeping only the old one would make the next refresh fail as reuse.
    /// - A refresh that is genuinely rejected (`.sessionRevoked` — GoTrue says
    ///   this refresh token is dead) clears the stored session, so this returns
    ///   nil exactly like a plain sign-out: the caller's resulting
    ///   `.notAuthenticated` is what shows the signed-out notice.
    /// - Any other refresh failure (offline, timeout, rate limit, 5xx, an
    ///   unusable reply) is treated as transient: the stored session is left
    ///   alone and its still-current (if soon to expire) access token is
    ///   returned, so a network blip never signs the user out.
    ///
    /// Nil when signed out or when the Keychain cannot be read right now, same
    /// as `keychainToken`. `service`'s default uses a short timeout: this runs
    /// silently before every rewrite call and must not itself consume the
    /// dictation watchdog's budget.
    static func refreshingKeychainToken(
        store: SessionStore = SessionStore(),
        service: AuthService = AuthService(timeout: 2),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> String? {
        guard case .success(let session?) = store.load() else { return nil }
        guard session.needsRefresh(now: now()) else { return session.accessToken }

        switch await service.refresh(session) {
        case .success(let refreshed):
            // Best-effort: a Keychain write failure here leaves the old session
            // in place (still holding a now-retired refresh token, but a still
            // valid access token is returned for this one call regardless), and
            // the next call just tries the refresh again.
            try? store.save(refreshed)
            return refreshed.accessToken
        case .failure(.sessionRevoked):
            store.clear()
            return nil
        case .failure:
            return session.accessToken
        }
    }

    /// Never throws: every failure is a `RewriteError`. Callers fall back to
    /// inserting the raw transcript on any failure (Section 3.2) and never block
    /// the user's workflow. Cancelling the calling Task returns `.cancelled`.
    func rewrite(transcript: String) async -> Result<String, RewriteError> {
        guard let token = await tokenProvider() else { return .failure(.notAuthenticated) }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/rewrite"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONEncoder().encode(RewriteRequestBody(transcript: transcript))

        do {
            // Streamed so an oversized body is abandoned as soon as it passes the
            // cap, instead of being buffered whole before anything looks at it.
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

    static func classify(networkError error: Error) -> RewriteError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            return .unreachable
        }
    }

    /// A rewrite of one dictation is a few KB. Anything past this is not one, and
    /// is rejected before it is decoded.
    static let maxResponseBytes = 256 * 1024

    static func interpret(status: Int, body: Data?) -> Result<String, RewriteError> {
        switch status {
        case 200..<300:
            guard let body = body, body.count <= maxResponseBytes,
                  let decoded = try? JSONDecoder().decode(RewriteResponseBody.self, from: body),
                  !decoded.rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .failure(.invalidResponse) }
            return .success(decoded.rewritten)
        case 401: return .failure(.unauthorized)
        case 402: return .failure(.requiresPro)
        case 413: return .failure(.tooLong)
        case 429: return .failure(.rateLimited)
        case 500..<600: return .failure(.unavailable)
        default: return .failure(.unexpectedStatus(status))
        }
    }
}

private struct RewriteRequestBody: Encodable {
    let transcript: String
}

private struct RewriteResponseBody: Decodable {
    let rewritten: String
}

/// Completing a redirect with nil delivers the 3xx response itself, which
/// `RewritePipeline.interpret` reports as `.unexpectedStatus`.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
