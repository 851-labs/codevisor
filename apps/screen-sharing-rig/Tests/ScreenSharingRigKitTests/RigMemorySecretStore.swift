import Foundation
import ScreenSharingRigKit

/// A `RigSecretStore` in memory, standing in for the login Keychain.
final class RigMemorySecretStore: RigSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var secrets: [String: String]
  init(_ secrets: [String: String] = [:]) { self.secrets = secrets }
  func read(_ account: String) -> String? { lock.withLock { secrets[account] } }
  func save(_ secret: String, for account: String) throws { lock.withLock { secrets[account] = secret } }
  func delete(_ account: String) { _ = lock.withLock { secrets.removeValue(forKey: account) } }
}
