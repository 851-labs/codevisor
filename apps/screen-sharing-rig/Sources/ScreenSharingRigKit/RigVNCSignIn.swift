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

/// What a direct VNC machine signs in with: a macOS account (username and
/// password: Apple's account sign-in, security type 30, 851-2342) or the VNC
/// password alone. Stored in the Keychain as the password itself when there's
/// no username (as before), else as JSON, so passwords saved earlier still read.
public struct RigVNCCredential: Sendable, Equatable {
  public var username: String?
  public var password: String

  public init(username: String? = nil, password: String) {
    self.username = username.flatMap { $0.isEmpty ? nil : $0 }
    self.password = password
  }

  public var encoded: String {
    guard let username,
      let data = try? JSONSerialization.data(
        withJSONObject: ["username": username, "password": password], options: [.sortedKeys])
    else { return password }
    return String(decoding: data, as: UTF8.self)
  }

  public static func decode(_ stored: String) -> Self {
    guard stored.hasPrefix("{"), let data = stored.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let password = object["password"]
    else { return Self(password: stored) }
    return Self(username: object["username"], password: password)
  }
}

/// Choosing the credential a direct VNC machine connects with, and keeping the
/// Keychain in step with what the server accepts. `verify` is one handshake
/// (TCP, security negotiation, authentication) with the given credential.
public enum RigVNCSignIn {
  /// A credential the user typed into the rig, and whether to keep it.
  public struct Typed: Sendable, Equatable {
    public var credential: RigVNCCredential
    public var remember: Bool

    public init(username: String? = nil, password: String, remember: Bool) {
      credential = RigVNCCredential(username: username, password: password)
      self.remember = remember
    }
  }

  public enum Outcome: Sendable, Equatable {
    /// Connect with this credential (nil: the server needs none).
    case signedIn(RigVNCCredential?)
    /// Ask the user; `reason` is the server's rejection, nil when nothing was stored.
    case needsPassword(reason: String?)
  }

  public static func signIn(
    machineId: String, password: RigVNCPassword, typed: Typed?, store: any RigSecretStore,
    verify: @Sendable (RigVNCCredential) async throws -> Void
  ) async throws -> Outcome {
    switch password {
    case .none: return .signedIn(nil)
    case .fixed(let fixed): return .signedIn(RigVNCCredential(password: fixed))
    case .keychain: break
    }
    let stored = store.read(machineId).map(RigVNCCredential.decode)
    guard let candidate = typed?.credential ?? stored, !candidate.password.isEmpty else {
      return .needsPassword(reason: nil)
    }
    do {
      try await verify(candidate)
    } catch RFBError.authenticationFailed(let reason) {
      if stored == candidate { store.delete(machineId) }
      return .needsPassword(reason: reason)
    }
    if let typed {
      if typed.remember { try store.save(candidate.encoded, for: machineId) } else { store.delete(machineId) }
    }
    return .signedIn(candidate)
  }
}
