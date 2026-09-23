import Foundation
import Security

/// Secrets the rig keeps per machine id: a server's bearer token, a VNC
/// server's password. The login Keychain in the app, memory in tests.
public protocol RigSecretStore: Sendable {
  func read(_ account: String) -> String?
  func save(_ secret: String, for account: String) throws
  func delete(_ account: String)
}

/// Generic passwords in the login Keychain under one service. Readable only
/// while this Mac is unlocked, never synced to iCloud. The rig is signed with a
/// stable identity, so the Keychain does not ask again after a rebuild.
public struct RigKeychain: RigSecretStore {
  public let service: String
  public init(service: String) { self.service = service }

  /// `ssh <target> codevisor token`, per Codevisor server machine.
  public static let machineTokens = RigKeychain(service: "com.codevisor.ScreenSharingRig.machine-token")
  /// The VNC Authentication password, per direct VNC machine.
  public static let vncPasswords = RigKeychain(service: "com.codevisor.ScreenSharingRig.vnc-password")

  public func read(_ account: String) -> String? {
    var query = match(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  public func save(_ secret: String, for account: String) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(secret.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
    var status = SecItemUpdate(match(account) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var add = match(account).merging(attributes) { $1 }
      add[kSecAttrLabel as String] = "Codevisor Screen Sharing Rig: \(account)"
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw RigKeychainError(status: status) }
  }

  public func delete(_ account: String) {
    SecItemDelete(match(account) as CFDictionary)
  }

  private func match(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

public struct RigKeychainError: LocalizedError, Equatable {
  public let status: OSStatus
  public var errorDescription: String? {
    let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return "Couldn't save to the Keychain: \(reason)"
  }
}

/// A store in memory: tests, and nothing else.
public final class RigMemorySecretStore: RigSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var secrets: [String: String]
  public init(_ secrets: [String: String] = [:]) { self.secrets = secrets }
  public func read(_ account: String) -> String? { lock.withLock { secrets[account] } }
  public func save(_ secret: String, for account: String) throws { lock.withLock { secrets[account] = secret } }
  public func delete(_ account: String) { _ = lock.withLock { secrets.removeValue(forKey: account) } }
}
