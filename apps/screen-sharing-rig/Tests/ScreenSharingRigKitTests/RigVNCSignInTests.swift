import Foundation
import ScreenSharing
import Testing

@testable import ScreenSharingRigKit

struct RigVNCSignInTests {
  /// Records the passwords handshakes were tried with; rejects all but `accepts` (and `user`, if set).
  final class Server: @unchecked Sendable {
    let accepts: String
    let user: String?
    private let lock = NSLock()
    private var tried: [String] = []
    private var triedUsers: [String?] = []
    init(accepts: String, user: String? = nil) {
      self.accepts = accepts
      self.user = user
    }
    var attempts: [String] { lock.withLock { tried } }
    var usernames: [String?] { lock.withLock { triedUsers } }
    func verify(_ credential: RigVNCCredential) throws {
      lock.withLock {
        tried.append(credential.password)
        triedUsers.append(credential.username)
      }
      guard credential.password == accepts, credential.username == user else {
        throw RFBError.authenticationFailed("Authentication failed")
      }
    }
  }

  private func signIn(
    _ password: RigVNCPassword = .keychain, typed: RigVNCSignIn.Typed? = nil, store: RigMemorySecretStore,
    server: Server
  ) async throws -> RigVNCSignIn.Outcome {
    try await RigVNCSignIn.signIn(machineId: "mac", password: password, typed: typed, store: store) {
      try server.verify($0)
    }
  }

  @Test func asksWithoutContactingTheServerWhenNothingIsStored() async throws {
    let server = Server(accepts: "make0405")
    #expect(try await signIn(store: RigMemorySecretStore(), server: server) == .needsPassword(reason: nil))
    #expect(server.attempts.isEmpty)
  }

  @Test func connectsWithTheStoredPassword() async throws {
    let server = Server(accepts: "make0405")
    let store = RigMemorySecretStore(["mac": "make0405"])
    #expect(try await signIn(store: store, server: server) == .signedIn(RigVNCCredential(password: "make0405")))
    #expect(server.attempts == ["make0405"])
  }

  @Test func rememberedPasswordIsStoredOnlyAfterTheServerAcceptsIt() async throws {
    let server = Server(accepts: "make0405")
    let store = RigMemorySecretStore()
    let wrong = RigVNCSignIn.Typed(password: "nope", remember: true)
    #expect(
      try await signIn(typed: wrong, store: store, server: server) == .needsPassword(reason: "Authentication failed"))
    #expect(store.read("mac") == nil)

    let right = RigVNCSignIn.Typed(password: "make0405", remember: true)
    #expect(
      try await signIn(typed: right, store: store, server: server) == .signedIn(RigVNCCredential(password: "make0405")))
    #expect(store.read("mac") == "make0405")
  }

  @Test func aRejectedStoredPasswordIsForgottenAndTheUserAskedWithTheServersReason() async throws {
    let server = Server(accepts: "changed")
    let store = RigMemorySecretStore(["mac": "make0405"])
    #expect(try await signIn(store: store, server: server) == .needsPassword(reason: "Authentication failed"))
    #expect(store.read("mac") == nil)
  }

  @Test func aRejectedTypedPasswordKeepsTheStoredOne() async throws {
    let server = Server(accepts: "other")
    let store = RigMemorySecretStore(["mac": "make0405"])
    let typo = RigVNCSignIn.Typed(password: "typo", remember: true)
    #expect(
      try await signIn(typed: typo, store: store, server: server) == .needsPassword(reason: "Authentication failed"))
    #expect(store.read("mac") == "make0405")
  }

  @Test func aPasswordNotToRememberConnectsAndClearsTheStoredOne() async throws {
    let server = Server(accepts: "make0405")
    let store = RigMemorySecretStore(["mac": "old"])
    let once = RigVNCSignIn.Typed(password: "make0405", remember: false)
    #expect(
      try await signIn(typed: once, store: store, server: server) == .signedIn(RigVNCCredential(password: "make0405")))
    #expect(store.read("mac") == nil)
  }

  @Test func otherFailuresAreErrorsAndLeaveTheStoredPassword() async throws {
    let store = RigMemorySecretStore(["mac": "make0405"])
    await #expect(throws: RFBError.securityUnsupported([30, 33, 36, 35])) {
      try await RigVNCSignIn.signIn(machineId: "mac", password: .keychain, typed: nil, store: store) { _ in
        throw RFBError.securityUnsupported([30, 33, 36, 35])
      }
    }
    #expect(store.read("mac") == "make0405")
  }

  @Test func fixedAndNoPasswordNeitherAskNorTouchTheStore() async throws {
    let server = Server(accepts: "x")
    let store = RigMemorySecretStore()
    #expect(
      try await signIn(.fixed("secret"), store: store, server: server)
        == .signedIn(RigVNCCredential(password: "secret")))
    #expect(try await signIn(.none, store: store, server: server) == .signedIn(nil))
    #expect(server.attempts.isEmpty)
    #expect(store.read("mac") == nil)
  }

  // MARK: Account sign-in (851-2342)

  @Test func aMacAccountIsTriedStoredAndReadBack() async throws {
    let server = Server(accepts: "correct horse", user: "alex")
    let store = RigMemorySecretStore()
    let typed = RigVNCSignIn.Typed(username: "alex", password: "correct horse", remember: true)
    let account = RigVNCCredential(username: "alex", password: "correct horse")
    #expect(try await signIn(typed: typed, store: store, server: server) == .signedIn(account))
    #expect(server.usernames == ["alex"])
    // Stored as JSON, and the next connection uses it without asking.
    #expect(store.read("mac")?.hasPrefix("{") == true)
    #expect(try await signIn(store: store, server: server) == .signedIn(account))
  }

  @Test func credentialsEncodeCompatibly() {
    // A password alone is stored as itself, as before this change: older entries read unchanged.
    #expect(RigVNCCredential(password: "make0405").encoded == "make0405")
    #expect(RigVNCCredential.decode("make0405") == RigVNCCredential(password: "make0405"))
    #expect(RigVNCCredential.decode("{not json") == RigVNCCredential(password: "{not json"))
    let account = RigVNCCredential(username: "alex", password: "p{a}ss")
    #expect(RigVNCCredential.decode(account.encoded) == account)
    #expect(RigVNCCredential(username: "", password: "x").username == nil, "an empty user name is the VNC password")
  }
}
