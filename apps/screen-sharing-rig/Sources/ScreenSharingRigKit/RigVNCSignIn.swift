import Foundation
import ScreenSharing

/// Where a direct VNC machine's password comes from.
public enum RigVNCPassword: Sendable, Equatable, Hashable {
  /// The server needs none.
  case none
  /// Known to the rig: the loopback server's, which the rig itself set.
  case fixed(String)
  /// Asked for once and kept in the login Keychain under the machine's id;
  /// forgotten when the server rejects it, so the next attempt asks again.
  case keychain
}

/// Choosing the password a direct VNC machine connects with, and keeping the
/// Keychain in step with what the server accepts. `verify` is one handshake
/// (TCP, security negotiation, authentication) with the given password.
public enum RigVNCSignIn {
  /// A password the user typed into the rig, and whether to keep it.
  public struct Typed: Sendable, Equatable {
    public var password: String
    public var remember: Bool
    public init(password: String, remember: Bool) {
      self.password = password
      self.remember = remember
    }
  }

  public enum Outcome: Sendable, Equatable {
    /// Connect with this password.
    case signedIn(password: String?)
    /// Ask the user; `reason` is the server's rejection, nil when nothing was stored.
    case needsPassword(reason: String?)
  }

  public static func signIn(
    machineId: String, password: RigVNCPassword, typed: Typed?, store: any RigSecretStore,
    verify: @Sendable (String) async throws -> Void
  ) async throws -> Outcome {
    switch password {
    case .none: return .signedIn(password: nil)
    case .fixed(let fixed): return .signedIn(password: fixed)
    case .keychain: break
    }
    let stored = store.read(machineId)
    guard let candidate = typed.map(\.password) ?? stored, !candidate.isEmpty else {
      return .needsPassword(reason: nil)
    }
    do {
      try await verify(candidate)
    } catch RFBError.authenticationFailed(let reason) {
      if stored == candidate { store.delete(machineId) }
      return .needsPassword(reason: reason)
    }
    if let typed {
      if typed.remember { try store.save(candidate, for: machineId) } else { store.delete(machineId) }
    }
    return .signedIn(password: candidate)
  }
}
