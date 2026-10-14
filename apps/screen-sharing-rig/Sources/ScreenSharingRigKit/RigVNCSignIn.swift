import Foundation
import ScreenSharing

public enum RigVNCPassword: Sendable, Equatable, Hashable {
  case none
  case fixed(String)
  case keychain
}

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

public enum RigVNCSignIn {
  public struct Typed: Sendable, Equatable {
    public var credential: RigVNCCredential
    public var remember: Bool

    public init(username: String? = nil, password: String, remember: Bool) {
      credential = RigVNCCredential(username: username, password: password)
      self.remember = remember
    }
  }

  public enum Outcome: Sendable, Equatable {
    case signedIn(RigVNCCredential?)
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

extension RigVNCSignIn {
  public enum PasswordChange: Sendable, Equatable {
    case keep, forget
    case replace(String)
  }

  public static func saved(machineId: String, store: any RigSecretStore) -> (userName: String, hasPassword: Bool) {
    guard let stored = store.read(machineId) else { return ("", false) }
    let credential = RigVNCCredential.decode(stored)
    return (credential.username ?? "", !credential.password.isEmpty)
  }

  @discardableResult
  public static func update(
    machineId: String, userName: String?, password: PasswordChange, store: any RigSecretStore
  ) throws -> Bool {
    let stored = store.read(machineId).map(RigVNCCredential.decode)
    switch password {
    case .forget:
      store.delete(machineId)
      return stored != nil
    case .replace(let new):
      try store.save(
        RigVNCCredential(username: userName ?? stored?.username, password: new).encoded, for: machineId)
      return true
    case .keep:
      guard let userName, let stored, userName != (stored.username ?? "") else { return false }
      try store.save(RigVNCCredential(username: userName, password: stored.password).encoded, for: machineId)
      return true
    }
  }
}
