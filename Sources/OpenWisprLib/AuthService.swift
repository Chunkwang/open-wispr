import Foundation

/// Email-code sign-in against Supabase's GoTrue endpoints (docs/auth-design.md,
/// sections 2 and 3). Auth calls go straight to Supabase, not through our proxy.
///
/// Never throws: every failure is an `AuthError`. Nothing here logs or prints
/// anything. The email address and the code travel only in POST bodies, never in a
/// URL, and no error carries a request or response body.
final class AuthService: Sendable {
    /// Hard cap on the sign-out request. The user is already signed out locally;
    /// the server call only revokes the refresh token, so it never makes them wait.
    static let logoutCap: TimeInterval = 3

    /// A GoTrue reply is a few hundred bytes. Anything past this is not one.
    static let maxResponseBytes = 64 * 1024

    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String
    private let now: @Sendable () -> Date
    private let logoutCap: TimeInterval

    /// Production configuration: `AuthConfig` URL and key, and an ephemeral,
    /// no-redirect, no-cookie session. `timeout` defaults to 10 s, the budget for
    /// an interactive sign-in the user is actively waiting on; the token refresh
    /// path (Task 3.5) passes a much shorter one, since it runs silently before a
    /// rewrite call and must not itself blow the dictation watchdog.
    convenience init(timeout: TimeInterval = 10) {
        self.init(
            session: RewritePipeline.makeSession(configuration: .ephemeral, timeout: timeout),
            baseURL: AuthConfig.url,
            anonKey: AuthConfig.anonKey
        )
    }

    /// `session` and `now` are injectable so tests never touch the network or the
    /// real clock.
    init(
        session: URLSession,
        baseURL: URL,
        anonKey: String,
        now: @escaping @Sendable () -> Date = { Date() },
        logoutCap: TimeInterval = AuthService.logoutCap
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.now = now
        self.logoutCap = logoutCap
    }

    // MARK: - requests

    /// Asks Supabase to email a sign-in code. Creates the account on first use.
    func requestCode(email: String) async -> Result<Void, AuthError> {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return .failure(.invalidEmail) }
        let request = makeRequest(path: "auth/v1/otp", body: OTPBody(email: email))
        switch await send(request) {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            if (200..<300).contains(reply.status) { return .success(()) }
            return .failure(AuthService.classify(reply, route: .requestCode))
        }
    }

    /// Exchanges the emailed code for a session. Nothing is stored here: the caller
    /// saves the session (`AuthCoordinator`).
    func verifyCode(email: String, code: String) async -> Result<AuthSession, AuthError> {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return .failure(.invalidEmail) }
        guard !code.isEmpty else { return .failure(.codeRejected) }
        let request = makeRequest(path: "auth/v1/verify", body: VerifyBody(email: email, token: code))
        switch await send(request) {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            guard (200..<300).contains(reply.status) else {
                return .failure(AuthService.classify(reply, route: .verifyCode))
            }
            return AuthService.session(from: reply.body, requestedEmail: email, now: now())
        }
    }

    /// Refreshes an expiring session (`AuthSession.needsRefresh`) via GoTrue's
    /// rotating refresh grant. Supabase issues a NEW refresh token on every
    /// successful call (rotation), so the caller must save the whole returned
    /// session, not just the access token: sending the old refresh token again
    /// after that would be rejected as already used.
    func refresh(_ session: AuthSession) async -> Result<AuthSession, AuthError> {
        let request = makeRequest(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: RefreshBody(refresh_token: session.refreshToken)
        )
        switch await send(request) {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            guard (200..<300).contains(reply.status) else {
                return .failure(AuthService.classify(reply, route: .refresh))
            }
            // A refresh reply is not required to repeat the user's email; fall
            // back to the session being refreshed, same as `requestedEmail` above.
            return AuthService.session(from: reply.body, requestedEmail: session.email, now: now())
        }
    }

    /// Best-effort server-side sign-out: revokes this session's refresh tokens.
    /// The result is ignored on purpose (the local session is already gone, and a
    /// failed revoke is not something the user can act on), and it is abandoned
    /// after `logoutCap` seconds.
    func signOut(_ session: AuthSession) async {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/v1/logout"), resolvingAgainstBaseURL: false
        ) else { return }
        components.queryItems = [URLQueryItem(name: "scope", value: "local")]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = logoutCap

        let cap = UInt64(max(logoutCap, 0) * 1_000_000_000)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await self.send(request) }
            group.addTask { try? await Task.sleep(nanoseconds: cap) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - transport

    private struct Reply {
        let status: Int
        let body: Data
        let retryAfter: TimeInterval?
    }

    private struct OTPBody: Encodable {
        let email: String
        let create_user = true
    }

    private struct VerifyBody: Encodable {
        let type = "email"
        let email: String
        let token: String
    }

    private struct RefreshBody: Encodable {
        let refresh_token: String
    }

    private func makeRequest<Body: Encodable>(path: String, query: [URLQueryItem] = [], body: Body) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func send(_ request: URLRequest) async -> Result<Reply, AuthError> {
        do {
            // Streamed so an oversized body is abandoned as soon as it passes the cap.
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > AuthService.maxResponseBytes { return .failure(.invalidResponse) }
            }
            return .success(Reply(
                status: http.statusCode,
                body: data,
                retryAfter: AuthService.retryAfter(from: http.value(forHTTPHeaderField: "Retry-After"))
            ))
        } catch {
            return .failure(AuthService.classify(networkError: error))
        }
    }

    // MARK: - interpretation

    enum Route { case requestCode, verifyCode, refresh }

    static func classify(networkError error: Error) -> AuthError {
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

    private static func classify(_ reply: Reply, route: Route) -> AuthError {
        classify(status: reply.status, errorCode: errorCode(in: reply.body), retryAfter: reply.retryAfter, route: route)
    }

    /// Decides from the HTTP status and Supabase's `error_code`. Message text is
    /// never consulted, because it is free text and changes between versions.
    ///
    /// On the `refresh` route, only the codes GoTrue uses for a genuinely dead
    /// refresh token (`refresh_token_not_found`, `refresh_token_already_used`,
    /// `session_not_found`, `session_expired`) become `.sessionRevoked`. Every
    /// other 4xx/5xx or network failure on that route (an unrecognised code, a
    /// rate limit, a 5xx, an unusable body) falls through to a transient error
    /// case instead, so `refreshingKeychainToken` knows to keep the session and
    /// try again next time rather than sign the user out over a network blip.
    static func classify(status: Int, errorCode: String?, retryAfter: TimeInterval?, route: Route) -> AuthError {
        let wait = retryAfter ?? AuthError.defaultRetryAfter
        switch status {
        case 500..<600:
            return .unavailable
        case 429:
            switch errorCode {
            case "over_email_send_rate_limit": return .sendRateLimited(retryAfter: wait)
            case "over_request_rate_limit": return .tooManyAttempts(retryAfter: wait)
            default:
                // Unknown limiter: the route says what the user was doing.
                return route == .requestCode ? .sendRateLimited(retryAfter: wait) : .tooManyAttempts(retryAfter: wait)
            }
        case 400..<500:
            switch (route, errorCode) {
            case (.verifyCode, "otp_expired"): return .codeRejected
            case (.verifyCode, "validation_failed") where status == 400 || status == 422: return .codeRejected
            case (.requestCode, "validation_failed") where status == 400 || status == 422: return .invalidEmail
            case (.requestCode, "email_address_invalid") where status == 400 || status == 422: return .invalidEmail
            case (.refresh, "refresh_token_not_found"), (.refresh, "refresh_token_already_used"),
                 (.refresh, "session_not_found"), (.refresh, "session_expired"):
                return .sessionRevoked
            default: return .invalidResponse
            }
        default:
            return .invalidResponse
        }
    }

    /// `error_code` (GoTrue), else `error` when it is a string (the OAuth-style
    /// shape). `msg`, `message` and `error_description` are free text and ignored.
    static func errorCode(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let code = object["error_code"] as? String, !code.isEmpty { return code }
        if let code = object["error"] as? String, !code.isEmpty { return code }
        return nil
    }

    /// Delta-seconds form only, clamped to 1...3600. An HTTP-date, zero, negative
    /// or missing value gives nil and the caller uses the 60 s default.
    static func retryAfter(from header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
              let seconds = Int(header), seconds > 0
        else { return nil }
        return TimeInterval(min(seconds, 3600))
    }

    private struct SessionPayload: Decodable {
        struct User: Decodable { let email: String? }
        let access_token: String
        let refresh_token: String
        let expires_at: TimeInterval?
        let expires_in: TimeInterval?
        let user: User?
    }

    /// A 2xx without a usable session (bad JSON, empty tokens, no expiry) is
    /// `invalidResponse`, never a half-signed-in state.
    static func session(from body: Data, requestedEmail: String, now: Date) -> Result<AuthSession, AuthError> {
        guard body.count <= maxResponseBytes,
              let payload = try? JSONDecoder().decode(SessionPayload.self, from: body),
              !payload.access_token.isEmpty, !payload.refresh_token.isEmpty
        else { return .failure(.invalidResponse) }

        let expiresAt: Date
        if let epoch = payload.expires_at, epoch > 0 {
            expiresAt = Date(timeIntervalSince1970: epoch)
        } else if let lifetime = payload.expires_in, lifetime > 0 {
            expiresAt = now.addingTimeInterval(lifetime)
        } else {
            return .failure(.invalidResponse)
        }

        let email = (payload.user?.email).flatMap { $0.isEmpty ? nil : $0 } ?? requestedEmail
        return .success(AuthSession(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token,
            expiresAt: expiresAt,
            email: email
        ))
    }
}
