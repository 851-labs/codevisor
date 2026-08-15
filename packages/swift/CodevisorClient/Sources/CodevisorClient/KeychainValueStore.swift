import Foundation
import Security

/// The Keychain services used by released builds are permanent identifiers:
/// changing them would orphan credentials already stored by Alpha users.
/// Development builds use a per-instance suffix so a differently signed dev
/// app never asks macOS for access to an Alpha build's login-Keychain items.
public enum KeychainCredentialServices {
    public static let productionMachine = "com.851labs.Codevisor.machine-token"
    public static let productionCloud = "com.851labs.Codevisor.cloud-session"

    public static var machine: String {
        scopedService(productionService: productionMachine)
    }

    public static var cloud: String {
        scopedService(productionService: productionCloud)
    }

    private static func scopedService(productionService: String) -> String {
        scopedService(
            productionService: productionService,
            isDevelopment: CodevisorAppVariant.isDevelopment,
            developmentInstanceID: CodevisorAppVariant.developmentInstanceID,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    /// Pure service-name resolution for deterministic tests.
    public static func scopedService(
        productionService: String,
        isDevelopment: Bool,
        developmentInstanceID: String?,
        bundleIdentifier: String?
    ) -> String {
        guard isDevelopment else { return productionService }

        let scope =
            nonempty(developmentInstanceID)
            ?? nonempty(bundleIdentifier)
            ?? "default"
        return "\(productionService).development.\(scope)"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Injectable SecItem surface. Production calls Security.framework directly;
/// tests use an in-memory implementation and never touch the developer's real
/// Keychain.
public struct KeychainOperations: @unchecked Sendable {
    public let copyMatching: ([String: Any]) -> (status: OSStatus, result: Any?)
    public let update: ([String: Any], [String: Any]) -> OSStatus
    public let add: ([String: Any]) -> OSStatus
    public let delete: ([String: Any]) -> OSStatus

    public static let live = KeychainOperations(
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

public struct KeychainStorageFailure: Error, Sendable {
    public let operation: String
    public let status: OSStatus
}

/// Shared string-value storage for both machine and cloud credentials.
///
/// Omitting `kSecUseDataProtectionKeychain` is intentional: macOS uses the
/// classic login Keychain, which does not require a provisioning-profile
/// access group, while iOS continues to use its normal platform Keychain.
public final class KeychainValueStore: @unchecked Sendable {
    private let service: String
    private let operations: KeychainOperations

    public init(service: String, operations: KeychainOperations = .live) {
        self.service = service
        self.operations = operations
    }

    public func value(forAccount account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let response = operations.copyMatching(query)
        if response.status == errSecItemNotFound { return nil }
        guard response.status == errSecSuccess,
            let data = response.result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainStorageFailure(
                operation: "read",
                status: response.status == errSecSuccess ? errSecDecode : response.status
            )
        }
        return value
    }

    public func saveValue(_ value: String, forAccount account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updateStatus = operations.update(
            query,
            [kSecValueData as String: data]
        )
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

    public func removeValue(forAccount account: String) throws {
        let status = operations.delete(baseQuery(account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorageFailure(operation: "delete", status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
