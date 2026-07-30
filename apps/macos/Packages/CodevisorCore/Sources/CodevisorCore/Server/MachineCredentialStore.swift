import Foundation
import Security

public protocol MachineCredentialStore: Sendable {
    func token(forMachineID id: String) throws -> String?
    func saveToken(_ token: String, forMachineID id: String) throws
    func removeToken(forMachineID id: String) throws
}

public struct MachineCredentialError: Error, LocalizedError, Sendable {
    public let operation: String
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Machine credential \(operation) failed: \(detail)"
    }
}

/// Device-local credential storage for remote Codevisor server tokens.
public final class KeychainMachineCredentialStore: MachineCredentialStore, @unchecked Sendable {
    public static let shared = KeychainMachineCredentialStore()

    private let service: String

    public init(service: String = "com.851labs.Codevisor.machine-token") {
        self.service = service
    }

    public func token(forMachineID id: String) throws -> String? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data
        else {
            throw MachineCredentialError(operation: "read", status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func saveToken(_ token: String, forMachineID id: String) throws {
        let data = Data(token.utf8)
        let query = baseQuery(id: id)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MachineCredentialError(operation: "update", status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw MachineCredentialError(operation: "insert", status: insertStatus)
        }
    }

    public func removeToken(forMachineID id: String) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MachineCredentialError(operation: "delete", status: status)
        }
    }

    private func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
    }
}

public final class InMemoryMachineCredentialStore: MachineCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    public init(tokens: [String: String] = [:]) {
        self.tokens = tokens
    }

    public func token(forMachineID id: String) throws -> String? {
        lock.withLock { tokens[id] }
    }

    public func saveToken(_ token: String, forMachineID id: String) throws {
        lock.withLock { tokens[id] = token }
    }

    public func removeToken(forMachineID id: String) throws {
        lock.withLock { tokens[id] = nil }
    }
}
