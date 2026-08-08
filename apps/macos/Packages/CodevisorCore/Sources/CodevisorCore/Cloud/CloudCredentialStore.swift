import Foundation
import Security

/// Device-local storage for the cloud account's session token and (when the
/// user points at a self-hosted instance) the custom server URL. The URL
/// isn't a secret, but keeping the pair together in one store is simpler than
/// splitting it across Keychain and preferences.
public protocol CloudCredentialStore: Sendable {
    func token() throws -> String?
    func saveToken(_ token: String) throws
    func removeToken() throws
    func serverURL() throws -> URL?
    /// Nil clears the custom server (back to the default instance).
    func saveServerURL(_ url: URL?) throws
    /// This app install's stable cloud device id (survives sign-outs so the
    /// hub sees one device, not a new one per session).
    func appDeviceId() throws -> String?
    func saveAppDeviceId(_ id: String) throws
    /// The app device's static X25519 secret key (raw 32 bytes) — the
    /// identity machines pin for end-to-end encrypted relay channels.
    func appSecretKey() throws -> Data?
    func saveAppSecretKey(_ key: Data) throws
}

/// The app device's relay identity: a stable device id plus static X25519
/// keypair, created on first use and persisted in the credential store.
public struct CloudAppDeviceIdentity: Sendable {
    public let deviceId: String
    /// Raw X25519 secret key (32 bytes).
    public let secretKey: Data
    /// base64url-unpadded public key, as presented in `hello`.
    public let publicKey: String

    public init(deviceId: String, secretKey: Data, publicKey: String) {
        self.deviceId = deviceId
        self.secretKey = secretKey
        self.publicKey = publicKey
    }
}

extension CloudCredentialStore {
    /// Returns the persisted app device identity, minting one on first use.
    public func ensureAppDeviceIdentity() throws -> CloudAppDeviceIdentity {
        let deviceId: String
        if let stored = try appDeviceId() {
            deviceId = stored
        } else {
            deviceId = UUID().uuidString.lowercased()
            try saveAppDeviceId(deviceId)
        }
        if let secret = try appSecretKey(),
           let publicKey = try? CloudChannelCrypto.publicKey(forSecretKey: secret) {
            return CloudAppDeviceIdentity(deviceId: deviceId, secretKey: secret, publicKey: publicKey)
        }
        let pair = CloudChannelCrypto.generateKeyPair()
        try saveAppSecretKey(pair.secretKey)
        return CloudAppDeviceIdentity(
            deviceId: deviceId,
            secretKey: pair.secretKey,
            publicKey: pair.publicKey
        )
    }
}

public struct CloudCredentialError: Error, LocalizedError, Sendable {
    public let operation: String
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Cloud credential \(operation) failed: \(detail)"
    }
}

public final class KeychainCloudCredentialStore: CloudCredentialStore, @unchecked Sendable {
    public static let shared = KeychainCloudCredentialStore()

    private static let tokenAccount = "session-token"
    private static let serverURLAccount = "server-url"
    private static let appDeviceIdAccount = "app-device-id"
    private static let appSecretKeyAccount = "app-device-secret-key"

    private let service: String

    public init(service: String = "com.851labs.Codevisor.cloud-session") {
        self.service = service
    }

    public func token() throws -> String? {
        try read(account: Self.tokenAccount)
    }

    public func saveToken(_ token: String) throws {
        try write(token, account: Self.tokenAccount)
    }

    public func removeToken() throws {
        try remove(account: Self.tokenAccount)
    }

    public func serverURL() throws -> URL? {
        try read(account: Self.serverURLAccount).flatMap(URL.init(string:))
    }

    public func saveServerURL(_ url: URL?) throws {
        if let url {
            try write(url.absoluteString, account: Self.serverURLAccount)
        } else {
            try remove(account: Self.serverURLAccount)
        }
    }

    public func appDeviceId() throws -> String? {
        try read(account: Self.appDeviceIdAccount)
    }

    public func saveAppDeviceId(_ id: String) throws {
        try write(id, account: Self.appDeviceIdAccount)
    }

    public func appSecretKey() throws -> Data? {
        try read(account: Self.appSecretKeyAccount)
            .flatMap { Data(base64Encoded: $0) }
    }

    public func saveAppSecretKey(_ key: Data) throws {
        try write(key.base64EncodedString(), account: Self.appSecretKeyAccount)
    }

    private func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data
        else {
            throw CloudCredentialError(operation: "read", status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CloudCredentialError(operation: "update", status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw CloudCredentialError(operation: "insert", status: insertStatus)
        }
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudCredentialError(operation: "delete", status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public final class InMemoryCloudCredentialStore: CloudCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?
    private var storedServerURL: URL?
    private var storedAppDeviceId: String?
    private var storedAppSecretKey: Data?

    public init(token: String? = nil, serverURL: URL? = nil) {
        storedToken = token
        storedServerURL = serverURL
    }

    public func token() throws -> String? {
        lock.withLock { storedToken }
    }

    public func saveToken(_ token: String) throws {
        lock.withLock { storedToken = token }
    }

    public func removeToken() throws {
        lock.withLock { storedToken = nil }
    }

    public func serverURL() throws -> URL? {
        lock.withLock { storedServerURL }
    }

    public func saveServerURL(_ url: URL?) throws {
        lock.withLock { storedServerURL = url }
    }

    public func appDeviceId() throws -> String? {
        lock.withLock { storedAppDeviceId }
    }

    public func saveAppDeviceId(_ id: String) throws {
        lock.withLock { storedAppDeviceId = id }
    }

    public func appSecretKey() throws -> Data? {
        lock.withLock { storedAppSecretKey }
    }

    public func saveAppSecretKey(_ key: Data) throws {
        lock.withLock { storedAppSecretKey = key }
    }
}
