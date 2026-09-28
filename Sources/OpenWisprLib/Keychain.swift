import Foundation
import Security

/// A Keychain call failed. Carries only the `OSStatus` (a public error code, never
/// a value), so an instance is safe to log.
public struct KeychainError: LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? { "Keychain error (OSStatus \(status))." }
}

/// The storage the rest of the app talks to. Production uses `SystemKeychain`;
/// tests inject an in-memory fake so nothing touches the real login Keychain.
///
/// `read` returns nil ONLY when the item does not exist. Any other failure (a
/// locked screen, `errSecInteractionNotAllowed`, a denied prompt) throws, so the
/// caller can tell "signed out" from "could not look", and never deletes or signs
/// anyone out because of the second.
protocol KeychainStoring: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    /// Deleting an item that is not there is not an error.
    func delete(account: String) throws
}

/// The four `Security` calls the real store makes, as closures so a test can
/// drive `SystemKeychain` through every status without a Keychain.
struct SecItemClient: Sendable {
    var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    var add: @Sendable (CFDictionary) -> OSStatus
    var delete: @Sendable (CFDictionary) -> OSStatus

    static let system = SecItemClient(
        copyMatching: { SecItemCopyMatching($0, $1) },
        update: { SecItemUpdate($0, $1) },
        add: { SecItemAdd($0, nil) },
        delete: { SecItemDelete($0) }
    )
}

/// Generic-password items under `Keychain.service`.
struct SystemKeychain: KeychainStoring {
    let client: SecItemClient

    init(client: SecItemClient = .system) {
        self.client = client
    }

    func read(account: String) throws -> Data? {
        var query = Keychain.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = client.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
        return data
    }

    /// Update in place first, so a failed write can never lose the value that was
    /// there (delete-then-add would). Add only when there is nothing to update.
    func write(_ data: Data, account: String) throws {
        let updated = client.update(
            Keychain.baseQuery(account: account) as CFDictionary,
            Keychain.updateAttributes(data: data) as CFDictionary
        )
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }

        let added = client.add(Keychain.addQuery(account: account, data: data) as CFDictionary)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    func delete(account: String) throws {
        let status = client.delete(Keychain.baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Minimal Keychain wrapper for the Supabase session (see `SessionStore`).
/// Per the TRD's v1 trust commitments, this is the ONLY thing stored here:
/// no third-party OAuth tokens exist until the v2 agent layer is built.
///
/// Values are never logged. Errors carry an `OSStatus` and nothing else.
public enum Keychain {
    static let service = "\(ProductInfo.bundleIdentifier).auth"

    /// The item is readable only while the Mac is unlocked and never leaves this
    /// device (no iCloud Keychain sync, no backup restore onto another Mac).
    static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// What `SecItemUpdate` changes. The accessibility class is restated so an
    /// item written by an older build is tightened, not only new ones.
    static func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
    }

    static func addQuery(account: String, data: Data) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility
        return query
    }

    static func read(account: String, in store: KeychainStoring = SystemKeychain()) throws -> Data? {
        try store.read(account: account)
    }

    static func write(_ data: Data, account: String, in store: KeychainStoring = SystemKeychain()) throws {
        try store.write(data, account: account)
    }

    static func delete(account: String, in store: KeychainStoring = SystemKeychain()) throws {
        try store.delete(account: account)
    }
}
