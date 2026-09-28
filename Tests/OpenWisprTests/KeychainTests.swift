import XCTest
import Security
@testable import OpenWisprLib

/// In-memory stand-in for the Keychain, shared by the sign-in tests. Tests never
/// touch the real login Keychain. Failures are injected per operation.
final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var _operations: [String] = []
    var readStatus: OSStatus?
    var writeStatus: OSStatus?
    var deleteStatus: OSStatus?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// "read:<account>", "write:<account>", "delete:<account>", in call order.
    var operations: [String] { lock.lock(); defer { lock.unlock() }; return _operations }

    func stored(account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    func put(_ data: Data, account: String) { lock.lock(); defer { lock.unlock() }; items[account] = data }

    func read(account: String) throws -> Data? {
        try locked {
            _operations.append("read:\(account)")
            if let status = readStatus { throw KeychainError(status: status) }
            return items[account]
        }
    }

    func write(_ data: Data, account: String) throws {
        try locked {
            _operations.append("write:\(account)")
            if let status = writeStatus { throw KeychainError(status: status) }
            items[account] = data
        }
    }

    func delete(account: String) throws {
        try locked {
            _operations.append("delete:\(account)")
            if let status = deleteStatus { throw KeychainError(status: status) }
            items[account] = nil
        }
    }
}

/// Drives `SystemKeychain` through every `OSStatus` with a scripted `SecItemClient`.
private final class ScriptedSecItems: @unchecked Sendable {
    private let lock = NSLock()
    var copyStatus: OSStatus = errSecSuccess
    var copyResult: Data?
    var updateStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    private(set) var calls: [String] = []
    private(set) var copyQuery: [String: Any] = [:]
    private(set) var updateQuery: [String: Any] = [:]
    private(set) var updateAttributes: [String: Any] = [:]
    private(set) var addQuery: [String: Any] = [:]
    private(set) var deleteQuery: [String: Any] = [:]

    lazy var client = SecItemClient(
        copyMatching: { [unowned self] query, result in
            lock.lock(); defer { lock.unlock() }
            calls.append("copy")
            copyQuery = query as! [String: Any]
            if copyStatus == errSecSuccess, let data = copyResult { result?.pointee = data as CFData }
            return copyStatus
        },
        update: { [unowned self] query, attributes in
            lock.lock(); defer { lock.unlock() }
            calls.append("update")
            updateQuery = query as! [String: Any]
            updateAttributes = attributes as! [String: Any]
            return updateStatus
        },
        add: { [unowned self] query in
            lock.lock(); defer { lock.unlock() }
            calls.append("add")
            addQuery = query as! [String: Any]
            return addStatus
        },
        delete: { [unowned self] query in
            lock.lock(); defer { lock.unlock() }
            calls.append("delete")
            deleteQuery = query as! [String: Any]
            return deleteStatus
        }
    )
}

final class KeychainTests: XCTestCase {
    private let secret = Data("do-not-log-me".utf8)

    private func assertThrowsStatus(_ status: OSStatus, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? KeychainError, KeychainError(status: status), file: file, line: line)
        }
    }

    // MARK: - read

    func testReadReturnsNilOnlyForItemNotFound() throws {
        let script = ScriptedSecItems()
        script.copyStatus = errSecItemNotFound
        XCTAssertNil(try SystemKeychain(client: script.client).read(account: "session"))
    }

    func testReadReturnsTheStoredData() throws {
        let script = ScriptedSecItems()
        script.copyResult = secret
        XCTAssertEqual(try SystemKeychain(client: script.client).read(account: "session"), secret)
    }

    func testReadTreatsEveryOtherStatusAsAnError() {
        // A locked screen or a dismissed access prompt is NOT "signed out".
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNotAvailable, errSecParam, -1] {
            let script = ScriptedSecItems()
            script.copyStatus = status
            assertThrowsStatus(status) { _ = try SystemKeychain(client: script.client).read(account: "session") }
        }
    }

    func testReadSuccessWithoutDataIsAnErrorNotNil() {
        let script = ScriptedSecItems()
        script.copyResult = nil
        assertThrowsStatus(errSecDecode) { _ = try SystemKeychain(client: script.client).read(account: "session") }
    }

    func testReadQueryIsScopedToServiceAndAccountAndAsksForData() throws {
        let script = ScriptedSecItems()
        script.copyResult = secret
        _ = try SystemKeychain(client: script.client).read(account: "session")
        XCTAssertEqual(script.copyQuery[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(script.copyQuery[kSecAttrService as String] as? String, Keychain.service)
        XCTAssertEqual(script.copyQuery[kSecAttrAccount as String] as? String, "session")
        XCTAssertEqual(script.copyQuery[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(script.copyQuery[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    // MARK: - write

    func testWriteUpdatesFirstAndDoesNotAddWhenTheItemExists() throws {
        let script = ScriptedSecItems()
        try SystemKeychain(client: script.client).write(secret, account: "session")
        XCTAssertEqual(script.calls, ["update"])
    }

    func testWriteAddsWhenTheUpdateFindsNothing() throws {
        let script = ScriptedSecItems()
        script.updateStatus = errSecItemNotFound
        try SystemKeychain(client: script.client).write(secret, account: "session")
        XCTAssertEqual(script.calls, ["update", "add"])
    }

    func testWriteNeverDeletesTheOldValue() throws {
        let script = ScriptedSecItems()
        script.updateStatus = errSecItemNotFound
        try SystemKeychain(client: script.client).write(secret, account: "session")
        XCTAssertFalse(script.calls.contains("delete"))
    }

    func testAFailedUpdateSurfacesItsStatusAndDoesNotFallBackToAdd() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDuplicateItem, -1] {
            let script = ScriptedSecItems()
            script.updateStatus = status
            assertThrowsStatus(status) { try SystemKeychain(client: script.client).write(self.secret, account: "session") }
            XCTAssertEqual(script.calls, ["update"], "status \(status)")
        }
    }

    func testAFailedAddSurfacesItsStatus() {
        let script = ScriptedSecItems()
        script.updateStatus = errSecItemNotFound
        script.addStatus = errSecInteractionNotAllowed
        assertThrowsStatus(errSecInteractionNotAllowed) { try SystemKeychain(client: script.client).write(self.secret, account: "session") }
    }

    func testTheAccessibilityClassIsSetOnTheUpdatePath() throws {
        let script = ScriptedSecItems()
        try SystemKeychain(client: script.client).write(secret, account: "session")
        XCTAssertEqual(
            script.updateAttributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(script.updateAttributes[kSecValueData as String] as? Data, secret)
    }

    func testTheAccessibilityClassIsSetOnTheAddPath() throws {
        let script = ScriptedSecItems()
        script.updateStatus = errSecItemNotFound
        try SystemKeychain(client: script.client).write(secret, account: "session")
        XCTAssertEqual(
            script.addQuery[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(script.addQuery[kSecValueData as String] as? Data, secret)
        XCTAssertEqual(script.addQuery[kSecAttrService as String] as? String, Keychain.service)
        XCTAssertEqual(script.addQuery[kSecAttrAccount as String] as? String, "session")
        XCTAssertEqual(script.addQuery[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testTheUpdateMatchesOnServiceAndAccountOnlyNeverOnTheValue() throws {
        let script = ScriptedSecItems()
        try SystemKeychain(client: script.client).write(secret, account: "session")
        XCTAssertEqual(script.updateQuery[kSecAttrService as String] as? String, Keychain.service)
        XCTAssertEqual(script.updateQuery[kSecAttrAccount as String] as? String, "session")
        XCTAssertNil(script.updateQuery[kSecValueData as String])
    }

    // MARK: - delete

    func testDeleteOfAMissingItemSucceeds() throws {
        let script = ScriptedSecItems()
        script.deleteStatus = errSecItemNotFound
        try SystemKeychain(client: script.client).delete(account: "session")
        XCTAssertEqual(script.deleteQuery[kSecAttrAccount as String] as? String, "session")
    }

    func testDeleteFailureIsSurfaced() {
        let script = ScriptedSecItems()
        script.deleteStatus = errSecInteractionNotAllowed
        assertThrowsStatus(errSecInteractionNotAllowed) { try SystemKeychain(client: script.client).delete(account: "session") }
    }

    // MARK: - errors carry no values

    func testKeychainErrorTextHoldsOnlyTheStatus() {
        let text = KeychainError(status: -25308).errorDescription ?? ""
        XCTAssertEqual(text, "Keychain error (OSStatus -25308).")
    }

    func testKeychainServiceKeepsTheBundleIdentifierPrefix() {
        XCTAssertTrue(Keychain.service.hasPrefix(ProductInfo.bundleIdentifier))
    }

    // MARK: - the in-memory fake behaves like the contract

    func testInMemoryFakeRoundTrips() throws {
        let fake = InMemoryKeychain()
        XCTAssertNil(try fake.read(account: "a"))
        try fake.write(secret, account: "a")
        XCTAssertEqual(try fake.read(account: "a"), secret)
        try fake.delete(account: "a")
        try fake.delete(account: "a")
        XCTAssertNil(try fake.read(account: "a"))
    }
}
