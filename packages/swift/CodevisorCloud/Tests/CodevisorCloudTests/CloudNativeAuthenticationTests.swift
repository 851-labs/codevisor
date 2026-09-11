import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Native cloud authentication")
struct CloudNativeAuthenticationTests {
  private let credential = CloudAppleCredential(
    challengeId: "challenge", authorizationCode: "apple-code", firstName: "Taylor", lastName: nil)

  @Test("Native sign-in adopts the verified session and its machines")
  func signIn() async throws {
    let (controller, client, store) = makeController()
    client.sessions["native-token"] = CloudSessionUser(userId: "apple-user", email: "relay@example.com")
    client.machinesResult = .success([testMachine("mac")])
    let context = try controller.authenticationContext(link: false)
    let challenge = try await controller.startNativeApple(context)
    #expect(challenge.nonce == "server-nonce")
    try await controller.completeNativeApple(credential, context: context)
    #expect(controller.state == .signedIn(userEmail: "relay@example.com"))
    #expect(controller.machines.map(\.deviceId) == ["mac"])
    #expect(try store.token() == "native-token")
  }

  @Test("Connecting Apple keeps the current account and updates connected providers")
  func link() async throws {
    let (controller, client, store) = await makeSignedIn(machines: [testMachine("mac")])
    client.appleToken = "t"
    client.providers = [.github, .apple]
    let context = try controller.authenticationContext(link: true)
    try await controller.completeNativeApple(credential, context: context)
    #expect(try store.token() == "t")
    #expect(controller.linkedProviders == [.github, .apple])
    #expect(controller.machines.map(\.deviceId) == ["mac"])
    #expect(controller.isCurrent(context))
  }

  @Test("A link response cannot replace the current session")
  func wrongAccount() async throws {
    let (controller, _, store) = await makeSignedIn(machines: [])
    let context = try controller.authenticationContext(link: true)
    await #expect(throws: CloudAccountClientError.invalidResponse) {
      try await controller.completeNativeApple(credential, context: context)
    }
    #expect(try store.token() == "t")
    #expect(controller.state.isSignedIn)
  }

  @Test("Signing out during a pending challenge prevents presenting a stale authorization")
  func signOutDuringChallenge() async throws {
    let (controller, client, _) = await makeSignedIn(machines: [])
    let started = TestSignal()
    let release = TestSignal()
    client.appleStart = {
      started.signal()
      await release.wait()
      return CloudAppleChallenge(id: "challenge", nonce: "nonce")
    }
    let context = try controller.authenticationContext(link: true)
    let task = Task { try await controller.startNativeApple(context) }
    await started.wait()
    controller.signOut()
    release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(controller.state == .signedOut)
  }

  @Test("Signing out during native code exchange prevents restoring the account")
  func signOutDuringExchange() async throws {
    let (controller, client, store) = makeController()
    let started = TestSignal()
    let release = TestSignal()
    client.appleComplete = {
      started.signal()
      await release.wait()
      return "stale-token"
    }
    let context = try controller.authenticationContext(link: false)
    let task = Task { try await controller.completeNativeApple(credential, context: context) }
    await started.wait()
    controller.signOut()
    release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(controller.state == .signedOut)
    #expect(try store.token() == nil)
  }

  @Test("Switching servers invalidates pending authentication")
  func serverChange() async throws {
    let (controller, _, store) = makeController()
    let context = try controller.authenticationContext(link: false)
    try await controller.setCustomServer(URL(string: "https://other.example"))
    await #expect(throws: CancellationError.self) {
      try await controller.completeNativeApple(credential, context: context)
    }
    #expect(try store.token() == nil)
  }

  @Test("Provider lookup errors are visible and retry recovers")
  func providerRetry() async {
    let (controller, client, _) = await makeSignedIn(machines: [])
    client.linkedError = CloudAccountClientError.httpStatus(503)
    await controller.refreshLinkedProviders()
    #expect(controller.linkedProviders == nil)
    #expect(controller.lastError != nil)
    client.linkedError = nil
    await controller.refreshLinkedProviders()
    #expect(controller.linkedProviders == [.github])
    controller.signOut()
    #expect(controller.linkedProviders == nil)
  }

  @Test("Browser linking keeps the native session and refreshes connected accounts")
  func browserLink() async throws {
    let (controller, client, store) = await makeSignedIn(machines: [])
    client.providers = [.github, .apple]
    let context = try controller.authenticationContext(link: true)
    try await controller.completeBrowserAuthentication(ott: "handoff", context: context)
    #expect(try store.token() == "t")
    #expect(controller.linkedProviders == [.github, .apple])
  }
}
