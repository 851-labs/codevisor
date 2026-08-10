import Foundation
#if os(macOS)
import LocalAuthentication
#endif
import Security

/// Injectable SecItem surface. Production uses Security.framework; tests use
/// an in-memory implementation so migration behavior is deterministic and
/// never touches the developer's real Keychain.
struct KeychainOperations: @unchecked Sendable {
    let copyMatching: ([String: Any]) -> (status: OSStatus, result: Any?)
    let update: ([String: Any], [String: Any]) -> OSStatus
    let add: ([String: Any]) -> OSStatus
    let delete: ([String: Any]) -> OSStatus

    static let live = KeychainOperations(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { attributes in
            SecItemAdd(attributes as CFDictionary, nil)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}

struct KeychainStorageFailure: Error, Sendable {
    let operation: String
    let status: OSStatus
}

/// String values in the app-private data-protection Keychain access group.
///
/// Older Codevisor builds accidentally used macOS's file-based login
/// Keychain. A modern miss gets one silent legacy lookup: an already-trusted
/// item migrates automatically, while an item that would require UI is left in
/// place. Background startup and reconnect tasks must never summon a Keychain
/// authorization dialog.
final class DataProtectionKeychainValueStore: @unchecked Sendable {
    private enum LegacyLookup {
        case value(String)
        case missing
        case interactionRequired
    }

    private let service: String
    private let operations: KeychainOperations
    private let lock = NSLock()
    private var cachedReads: [String: Result<String?, KeychainStorageFailure>] = [:]

    /// A marker prevents a deliberate removal from resurrecting the untouched
    /// legacy value on the next launch. It also avoids probing the legacy
    /// Keychain forever for accounts that never had an old value.
    private static let migrationMarkerPrefix = "codevisor.data-protection-migrated."

    init(service: String, operations: KeychainOperations = .live) {
        self.service = service
        self.operations = operations
    }

    func value(forAccount account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedReads[account] {
            return try cached.get()
        }

        do {
            let value = try loadValue(forAccount: account)
            cachedReads[account] = .success(value)
            return value
        } catch let failure as KeychainStorageFailure {
            // A broken or unavailable Keychain must not become a hot-looping
            // system call when a relay transport retries in the background.
            cachedReads[account] = .failure(failure)
            throw failure
        }
    }

    func saveValue(_ value: String, forAccount account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            try writeModernValue(value, forAccount: account)
            cachedReads[account] = .success(value)
        } catch let failure as KeychainStorageFailure {
            cachedReads[account] = .failure(failure)
            throw failure
        }
    }

    func removeValue(forAccount account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            // Commit the tombstone before deleting the modern value. If the
            // delete fails, the still-present modern value continues to win;
            // if it succeeds, legacy fallback stays disabled.
            try writeModernValue("1", forAccount: migrationMarkerAccount(for: account))
            let status = operations.delete(modernQuery(account: account))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStorageFailure(operation: "delete", status: status)
            }
            cachedReads[account] = .success(nil)
        } catch let failure as KeychainStorageFailure {
            cachedReads[account] = .failure(failure)
            throw failure
        }
    }

    private func loadValue(forAccount account: String) throws -> String? {
        if let modern = try readModernValue(forAccount: account) {
            return modern
        }
        if try readModernValue(forAccount: migrationMarkerAccount(for: account)) != nil {
            return nil
        }

        #if os(macOS)
        switch try readLegacyValueSilently(forAccount: account) {
        case let .value(value):
            try writeModernValue(value, forAccount: account)
            guard try readModernValue(forAccount: account) == value else {
                throw KeychainStorageFailure(operation: "migration verification", status: errSecDecode)
            }
            return value
        case .missing:
            // Best effort: failure only means another silent legacy probe next
            // launch, not failure to read a credential that does not exist.
            try? writeModernValue("1", forAccount: migrationMarkerAccount(for: account))
            return nil
        case .interactionRequired:
            // The current app signature is not trusted for this legacy item.
            // Treat it as unavailable; sign-in/pairing writes a new isolated
            // value without showing an authorization-dialog storm.
            return nil
        }
        #else
        return nil
        #endif
    }

    private func readModernValue(forAccount account: String) throws -> String? {
        var query = modernQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let response = operations.copyMatching(query)
        if response.status == errSecItemNotFound { return nil }
        guard response.status == errSecSuccess,
              let data = response.result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainStorageFailure(operation: "read", status: response.status == errSecSuccess ? errSecDecode : response.status)
        }
        return value
    }

    #if os(macOS)
    private func readLegacyValueSilently(forAccount account: String) throws -> LegacyLookup {
        var query = legacyQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authenticationContext
        let response = operations.copyMatching(query)
        if response.status == errSecItemNotFound { return .missing }
        if response.status == errSecInteractionNotAllowed
            || response.status == errSecAuthFailed
            || response.status == errSecUserCanceled {
            return .interactionRequired
        }
        guard response.status == errSecSuccess,
              let data = response.result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainStorageFailure(operation: "legacy read", status: response.status == errSecSuccess ? errSecDecode : response.status)
        }
        return .value(value)
    }
    #endif

    private func writeModernValue(_ value: String, forAccount account: String) throws {
        let data = Data(value.utf8)
        let query = modernQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = operations.update(query, update)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStorageFailure(operation: "update", status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = operations.add(insert)
        guard insertStatus == errSecSuccess else {
            throw KeychainStorageFailure(operation: "insert", status: insertStatus)
        }
    }

    private func modernQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicitly select the iOS-style data-protection implementation
            // on macOS. Other Apple platforms already behave this way.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    #if os(macOS)
    private func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif

    private func migrationMarkerAccount(for account: String) -> String {
        Self.migrationMarkerPrefix + account
    }
}
