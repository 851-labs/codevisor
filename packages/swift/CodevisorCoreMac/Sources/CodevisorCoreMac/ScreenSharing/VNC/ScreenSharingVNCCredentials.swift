import CodevisorClient
import ComposableArchitecture
import Foundation

/// Where VNC passwords live: the Keychain, one item per "host:port" account.
/// The reducer saves through this when a target is entered or forgotten; the
/// backend reads through it at connection time, so a password changed in
/// Keychain Access is picked up by the next connection.
@DependencyClient
public struct ScreenSharingVNCCredentials: Sendable {
  public var password: @Sendable (_ account: String) async -> String? = { _ in nil }
  /// nil removes the item.
  public var save: @Sendable (_ account: String, _ password: String?) async throws -> Void
}

extension ScreenSharingVNCCredentials: DependencyKey {
  public static var liveValue: Self { keychain(KeychainValueStore(service: KeychainCredentialServices.vnc)) }
  public static var testValue: Self { Self() }

  public static func keychain(_ store: KeychainValueStore) -> Self {
    Self(
      password: { account in try? store.value(forAccount: account) },
      save: { account, password in
        if let password {
          try store.saveValue(password, forAccount: account)
        } else {
          try store.removeValue(forAccount: account)
        }
      })
  }
}
