import XCTest
@testable import OpenWisprLib

final class AuthConfigTests: XCTestCase {
    private func jwt(role: String) -> String {
        func b64(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "HS256", "typ": "JWT"])).\(b64(["role": role, "iss": "supabase"])).c2ln"
    }

    // MARK: - the shipped values

    func testReleaseDefaultsNeverResolve() {
        XCTAssertEqual(AuthConfig.defaultURL.absoluteString, "https://auth.invalid")
    }

    func testTheShippedKeyIsNotAServiceRoleJWTAndNotASecretKey() {
        let key = AuthConfig.defaultAnonKey
        XCTAssertFalse(key.hasPrefix("sb_secret_"))
        XCTAssertNotEqual(AuthConfig.jwtRole(of: key), "service_role")
        XCTAssertTrue(AuthConfig.isPublicKey(key))
        XCTAssertFalse(key.isEmpty)
    }

    func testTheShippedKeyIsNotAnyJWTWithAPrivilegedRole() {
        // A public anon key may be a JWT with role "anon"; the placeholder is not
        // a JWT at all. Either way no privileged role is allowed.
        if let role = AuthConfig.jwtRole(of: AuthConfig.defaultAnonKey) {
            XCTAssertEqual(role, "anon")
        }
    }

    // MARK: - isPublicKey

    func testRefusesServiceRoleJWTsAndSecretKeys() {
        XCTAssertFalse(AuthConfig.isPublicKey(jwt(role: "service_role")))
        XCTAssertFalse(AuthConfig.isPublicKey("sb_secret_abcdef"))
        XCTAssertFalse(AuthConfig.isPublicKey("SB_SECRET_abcdef"))
    }

    func testAcceptsAnonJWTsAndPublishableKeys() {
        XCTAssertTrue(AuthConfig.isPublicKey(jwt(role: "anon")))
        XCTAssertTrue(AuthConfig.isPublicKey("sb_publishable_abc123"))
    }

    func testRefusesEmptyOversizedAndHeaderUnsafeKeys() {
        XCTAssertFalse(AuthConfig.isPublicKey(""))
        XCTAssertFalse(AuthConfig.isPublicKey("has space"))
        XCTAssertFalse(AuthConfig.isPublicKey("line\nbreak"))
        XCTAssertFalse(AuthConfig.isPublicKey(String(repeating: "a", count: 2049)))
    }

    func testJwtRoleReadsUnpaddedBase64URL() {
        XCTAssertEqual(AuthConfig.jwtRole(of: jwt(role: "service_role")), "service_role")
        XCTAssertNil(AuthConfig.jwtRole(of: "not-a-jwt"))
        XCTAssertNil(AuthConfig.jwtRole(of: "a.b.c"))
    }

    // MARK: - URL override rules (same as the proxy URL)

    func testURLOverrideIgnoredWhenNotAllowed() {
        XCTAssertEqual(AuthConfig.resolveURL(override: "https://evil.test", allowOverride: false), AuthConfig.defaultURL)
        XCTAssertEqual(AuthConfig.resolveURL(override: "http://127.0.0.1:54321", allowOverride: false), AuthConfig.defaultURL)
    }

    func testURLOverrideAcceptsHTTPSAndLoopbackHTTPOnly() {
        XCTAssertEqual(AuthConfig.resolveURL(override: "https://abc.supabase.co", allowOverride: true).absoluteString, "https://abc.supabase.co")
        XCTAssertEqual(AuthConfig.resolveURL(override: "http://127.0.0.1:54321", allowOverride: true).absoluteString, "http://127.0.0.1:54321")
        XCTAssertEqual(AuthConfig.resolveURL(override: "http://localhost:54321", allowOverride: true).absoluteString, "http://localhost:54321")
    }

    func testURLOverrideRejectsPlainHTTPToARemoteHostAndOtherSchemes() {
        for bad in ["http://evil.test", "http://192.168.1.5:54321", "ftp://localhost", "file:///etc/passwd", "not a url", "", "http://127.0.0.1.evil.test"] {
            XCTAssertEqual(AuthConfig.resolveURL(override: bad, allowOverride: true), AuthConfig.defaultURL, bad)
        }
    }

    func testNoURLOverrideUsesTheDefault() {
        XCTAssertEqual(AuthConfig.resolveURL(override: nil, allowOverride: true), AuthConfig.defaultURL)
    }

    // MARK: - resolveBaseURL keeps its proxy default and takes another

    func testResolveBaseURLStillDefaultsToTheProxy() {
        XCTAssertEqual(RewritePipeline.resolveBaseURL(override: "http://evil.test", allowOverride: true), RewritePipeline.defaultProxyURL)
        XCTAssertNotEqual(RewritePipeline.defaultProxyURL, AuthConfig.defaultURL)
    }

    func testResolveBaseURLFallsBackToTheGivenDefault() {
        let other = URL(string: "https://other.invalid")!
        XCTAssertEqual(RewritePipeline.resolveBaseURL(override: nil, allowOverride: true, default: other), other)
        XCTAssertEqual(RewritePipeline.resolveBaseURL(override: "https://ok.test", allowOverride: false, default: other), other)
        XCTAssertEqual(RewritePipeline.resolveBaseURL(override: "https://ok.test", allowOverride: true, default: other).absoluteString, "https://ok.test")
    }

    // MARK: - key override rules

    func testKeyOverrideIgnoredWhenNotAllowed() {
        XCTAssertEqual(AuthConfig.resolveAnonKey(override: "sb_publishable_dev", allowOverride: false), AuthConfig.defaultAnonKey)
    }

    func testKeyOverrideAcceptedWhenAllowedAndTrimmed() {
        XCTAssertEqual(AuthConfig.resolveAnonKey(override: "  sb_publishable_dev\n", allowOverride: true), "sb_publishable_dev")
    }

    func testKeyOverrideNeverAcceptsASecret() {
        XCTAssertEqual(AuthConfig.resolveAnonKey(override: jwt(role: "service_role"), allowOverride: true), AuthConfig.defaultAnonKey)
        XCTAssertEqual(AuthConfig.resolveAnonKey(override: "sb_secret_xyz", allowOverride: true), AuthConfig.defaultAnonKey)
        XCTAssertEqual(AuthConfig.resolveAnonKey(override: "", allowOverride: true), AuthConfig.defaultAnonKey)
        XCTAssertEqual(AuthConfig.resolveAnonKey(override: nil, allowOverride: true), AuthConfig.defaultAnonKey)
    }

    func testTheProcessResolvedValuesAreValid() {
        XCTAssertTrue(AuthConfig.isPublicKey(AuthConfig.anonKey))
        XCTAssertNotNil(AuthConfig.url.host)
    }
}
