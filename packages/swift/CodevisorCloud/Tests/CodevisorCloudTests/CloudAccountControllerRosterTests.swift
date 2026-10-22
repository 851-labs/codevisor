import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCloud

@MainActor
@Suite("CloudAccountController roster persistence")
struct CloudAccountControllerRosterTests {
  private static let server = CloudAccountController.defaultServerURL.absoluteString

  private func cachedRoster(
    _ machines: [CloudMachine] = [testMachine("m1")],
    serverURL: String = server,
    email: String? = "cached@example.com"
  ) -> CachedRoster {
    CachedRoster(serverURL: serverURL, userEmail: email, machines: machines)
  }

  @Test("A token plus cached roster publishes machines before any network answer")
  func cachedRosterIsImmediate() async throws {
    let client = FakeCloudClient()
    let gate = TestSignal()
    client.sessionGate = gate
    client.sessions["t"] = CloudSessionUser(userId: "u1", email: "fresh@example.com")
    client.machinesResult = .success([testMachine("m1"), testMachine("m2")])
    let store = InMemoryCloudCredentialStore(token: "t", roster: cachedRoster())
    let (controller, _, _) = makeController(client: client, store: store)

    await controller.bootstrap()

    #expect(controller.state == .signedIn(userEmail: "cached@example.com"))
    #expect(controller.machines.map(\.deviceId) == ["m1"])
    #expect(controller.hasCompletedBootstrap)
    #expect(!controller.isRosterVerified)
    #expect(client.discoverCount == 0)

    gate.signal()
    await controller.validation.task?.value

    #expect(controller.isRosterVerified)
    #expect(controller.state == .signedIn(userEmail: "fresh@example.com"))
    #expect(controller.machines.map(\.deviceId) == ["m1", "m2"])
    #expect(store.loadRoster()?.machines.map(\.deviceId) == ["m1", "m2"])
    #expect(store.loadRoster()?.userEmail == "fresh@example.com")
  }

  @Test("A launch cancelled during validation stays incomplete until the next bootstrap")
  func cancelledLaunchStaysIncomplete() async throws {
    let client = FakeCloudClient()
    let gate = TestSignal()
    client.sessionGate = gate
    client.sessions["t"] = CloudSessionUser(userId: "u1", email: "fresh@example.com")
    client.machinesResult = .success([testMachine("m1")])
    let store = InMemoryCloudCredentialStore(token: "t")
    let (controller, _, _) = makeController(client: client, store: store)

    let launch = Task { await controller.bootstrap() }
    #expect(await waitUntil { controller.state == .validating })
    launch.cancel()
    gate.signal()
    await launch.value

    #expect(controller.state == .signedIn(userEmail: "fresh@example.com"))
    #expect(controller.isRosterVerified)
    #expect(!controller.hasCompletedBootstrap)

    await controller.bootstrap()

    #expect(controller.hasCompletedBootstrap)
    #expect(controller.machines.map(\.deviceId) == ["m1"])
  }

  @Test("A network error keeps the cached session and retries with backoff until verified")
  func networkErrorRetries() async throws {
    let client = FakeCloudClient()
    client.sessionError = URLError(.notConnectedToInternet)
    client.sessions["t"] = CloudSessionUser(userId: "u1", email: "cached@example.com")
    client.machinesResult = .success([testMachine("m1"), testMachine("m2")])
    let store = InMemoryCloudCredentialStore(token: "t", roster: cachedRoster())
    let clock = TestClock()
    let (controller, _, _) = makeController(client: client, store: store, retryClock: clock)

    await controller.bootstrap()
    await controller.validation.task?.value

    #expect(controller.state == .signedIn(userEmail: "cached@example.com"))
    #expect(controller.machines.map(\.deviceId) == ["m1"])
    #expect(!controller.isRosterVerified)
    #expect(try store.token() == "t")
    #expect(store.loadRoster() == cachedRoster())

    await clock.waitForSleep(.seconds(1))
    var retry = controller.validation.retryTask
    clock.advance(by: .seconds(1))
    await retry?.value
    await controller.validation.task?.value
    #expect(controller.state.isSignedIn)
    await clock.waitForSleep(.seconds(2))

    client.sessionError = nil
    client.machinesResult = .failure(CloudAccountClientError.httpStatus(503))
    retry = controller.validation.retryTask
    clock.advance(by: .seconds(2))
    await retry?.value
    await controller.validation.task?.value
    #expect(controller.state.isSignedIn)
    #expect(!controller.isRosterVerified)
    await clock.waitForSleep(.seconds(4))

    client.machinesResult = .success([testMachine("m1"), testMachine("m2")])
    retry = controller.validation.retryTask
    clock.advance(by: .seconds(4))
    await retry?.value
    await controller.validation.task?.value

    #expect(controller.isRosterVerified)
    #expect(controller.machines.map(\.deviceId) == ["m1", "m2"])
    #expect(controller.validation.retryTask == nil)
    #expect(clock.pendingCount == 0)
  }

  @Test("The retry delay doubles and caps at sixty seconds")
  func backoffCaps() async {
    let client = FakeCloudClient()
    client.sessionError = URLError(.timedOut)
    let clock = TestClock()
    let (controller, _, _) = makeController(
      client: client,
      store: InMemoryCloudCredentialStore(token: "t", roster: cachedRoster()),
      retryClock: clock
    )
    await controller.bootstrap()
    await controller.validation.task?.value

    var requested: [Int: Int] = [:]
    for seconds in [1, 2, 4, 8, 16, 32, 60, 60] {
      requested[seconds, default: 0] += 1
      await clock.waitForSleep(.seconds(seconds), count: requested[seconds, default: 1])
      let retry = controller.validation.retryTask
      clock.advance(by: .seconds(seconds))
      await retry?.value
      await controller.validation.task?.value
    }
    #expect(controller.state.isSignedIn)
    #expect(clock.requestCount(.seconds(60)) >= 2)
    #expect(clock.requestCount(.seconds(64)) == 0)
    controller.signOut()
  }

  @Test("A 401 during validation signs out and clears the token and roster")
  func unauthorizedSignsOut() async throws {
    let client = FakeCloudClient()
    client.sessionError = CloudAccountClientError.httpStatus(401)
    let store = InMemoryCloudCredentialStore(token: "t", roster: cachedRoster())
    let (controller, _, _) = makeController(client: client, store: store)

    await controller.bootstrap()
    #expect(controller.state.isSignedIn)
    await controller.validation.task?.value

    #expect(controller.state == .signedOut)
    #expect(controller.machines.isEmpty)
    #expect(try store.token() == nil)
    #expect(store.loadRoster() == nil)
    #expect(controller.validation.retryTask == nil)
  }

  @Test("A 401 from the machine list also signs out and clears the roster")
  func unauthorizedMachineListSignsOut() async throws {
    let client = FakeCloudClient()
    client.sessions["t"] = CloudSessionUser(userId: "u1", email: "cached@example.com")
    client.machinesResult = .failure(CloudAccountClientError.httpStatus(401))
    let store = InMemoryCloudCredentialStore(token: "t", roster: cachedRoster())
    let (controller, _, _) = makeController(client: client, store: store)

    await controller.bootstrap()
    await controller.validation.task?.value

    #expect(controller.state == .signedOut)
    #expect(try store.token() == nil)
    #expect(store.loadRoster() == nil)
    #expect(controller.validation.retryTask == nil)
  }

  @Test("A successful refresh persists the roster and marks it verified")
  func refreshSavesRoster() async {
    let machines = [testMachine("m1"), testMachine("m2", online: false)]
    let (controller, _, store) = await makeSignedIn(machines: machines)

    #expect(controller.isRosterVerified)
    #expect(
      store.loadRoster()
        == CachedRoster(serverURL: Self.server, userEmail: nil, machines: machines))
  }

  @Test("A roster cached against a different server is ignored and cleared")
  func foreignServerRosterIgnored() async throws {
    let client = FakeCloudClient()
    client.sessionError = URLError(.notConnectedToInternet)
    let store = InMemoryCloudCredentialStore(
      token: "t",
      roster: cachedRoster(serverURL: "https://cloud.example.com")
    )
    let (controller, _, _) = makeController(client: client, store: store)

    await controller.bootstrap()

    #expect(controller.state == .signedIn(userEmail: nil))
    #expect(controller.machines.isEmpty)
    #expect(!controller.isRosterVerified)
    #expect(store.loadRoster() == nil)
    #expect(client.sessionTokens == ["t"])
    controller.signOut()
  }

  @Test("retryIfUnverified validates immediately, skipping the backoff wait")
  func retryIfUnverifiedValidatesNow() async {
    let client = FakeCloudClient()
    client.sessionError = URLError(.networkConnectionLost)
    client.sessions["t"] = CloudSessionUser(userId: "u1", email: "cached@example.com")
    client.machinesResult = .success([testMachine("m2")])
    let clock = TestClock()
    let (controller, _, store) = makeController(
      client: client,
      store: InMemoryCloudCredentialStore(token: "t", roster: cachedRoster()),
      retryClock: clock
    )
    await controller.bootstrap()
    await controller.validation.task?.value
    await clock.waitForSleep(.seconds(1))

    client.sessionError = nil
    await controller.retryIfUnverified()

    #expect(controller.isRosterVerified)
    #expect(controller.machines.map(\.deviceId) == ["m2"])
    #expect(store.loadRoster()?.machines.map(\.deviceId) == ["m2"])
    #expect(clock.pendingCount == 0)
    #expect(controller.validation.retryTask == nil)

    let sessionCalls = client.sessionTokens.count
    await controller.retryIfUnverified()
    #expect(client.sessionTokens.count == sessionCalls)
  }

  @Test("Sign-out clears the persisted roster and verification")
  func signOutClearsRoster() async {
    let (controller, _, store) = await makeSignedIn(machines: [testMachine("m1")])
    #expect(store.loadRoster() != nil)

    controller.signOut()

    #expect(store.loadRoster() == nil)
    #expect(!controller.isRosterVerified)
    #expect(controller.machines.isEmpty)
  }

  @Test("A roster without a session is discarded at launch")
  func orphanRosterCleared() async {
    let store = InMemoryCloudCredentialStore(roster: cachedRoster())
    let (controller, client, _) = makeController(store: store)

    await controller.bootstrap()

    #expect(controller.state == .signedOut)
    #expect(controller.machines.isEmpty)
    #expect(store.loadRoster() == nil)
    #expect(client.discoverCount == 1)
  }
}
