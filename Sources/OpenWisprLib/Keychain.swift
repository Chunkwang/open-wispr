import Foundation
import Security

/// Minimal Keychain wrapper for the Supabase session token.
/// Per the TRD's v1 trust commitments, this is the ONLY thing stored here —
/// no third-party OAuth tokens exist until the v2 agent layer is built.
public enum Keychain {
    private static let service = "com.goprimy.dictation-wip.auth"

    public static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
