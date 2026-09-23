import Foundation
import ScreenSharing
import Testing

@testable import ScreenSharingRigKit

struct RigVNCSignInTests {
  /// Records the passwords handshakes were tried with; rejects all but `accepts`.
  final class Server: @unchecked Sendable {
    let accepts: String
    private let lock = NSLock()
    private var tried: [String] = []
    init(accepts: String) { self.accepts = accepts }
    var attempts: [String] { lock.withLock { tried } }
    func verify(_ password: String) throws {
      lock.withLock { tried.append(password) }
      guard password == accepts else { throw RFBError.authenticationFailed("Authentication failed") }
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
    #expect(try await signIn(store: store, server: server) == .signedIn(password: "make0405"))
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
    #expect(try await signIn(typed: right, store: store, server: server) == .signedIn(password: "make0405"))
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
    #expect(try await signIn(typed: once, store: store, server: server) == .signedIn(password: "make0405"))
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
    #expect(try await signIn(.fixed("secret"), store: store, server: server) == .signedIn(password: "secret"))
    #expect(try await signIn(.none, store: store, server: server) == .signedIn(password: nil))
    #expect(server.attempts.isEmpty)
    #expect(store.read("mac") == nil)
  }
}
