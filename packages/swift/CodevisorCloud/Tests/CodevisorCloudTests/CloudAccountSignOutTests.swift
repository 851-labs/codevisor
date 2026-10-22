import Foundation
import Testing
import CodevisorTestSupport
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

@MainActor
@Suite("CloudAccountController sign-out")
struct CloudAccountSignOutTests {
  @Test("Sign-out deregisters an app-managed local machine and revokes it")
  func signOutDeregistersAppManagedMachine() async throws {
    let (controller, client, localServer) = await makeSignedInWithLocalServer()
    #expect(localServer.connects.count == 1)

    controller.signOut()
    await controller.localRegistration.deregistrationTask?.value

    #expect(localServer.disconnects == 1)
    #expect(client.removals == ["local-device-1"])
  }

  @Test("A session the cloud ends signs the app out but keeps this machine on the account")
  func endedSessionKeepsAppManagedMachine() async throws {
    let (controller, client, localServer) = await makeSignedInWithLocalServer()
    #expect(localServer.connects.count == 1)

    client.machinesResult = .failure(CloudAccountClientError.httpStatus(401))
    await controller.refreshMachines()
    await controller.localRegistration.deregistrationTask?.value

    #expect(!controller.state.isSignedIn)
    #expect(localServer.disconnects == 0)
    #expect(client.removals.isEmpty)
  }

  @Test("Signing in replaces an app registration the cloud has refused")
  func signInReplacesRefusedAppRegistration() async throws {
    let (_, _, localServer) = await makeSignedInWithLocalServer(
      registration: ServerCloudRegistration(
        connected: true,
        deviceId: "stale-device",
        state: "revoked",
        managedBy: "app"
      )
    )

    #expect(localServer.disconnects == 1)
    #expect(localServer.connects.count == 1)
  }

  @Test("Signing in keeps a refused CLI registration: it isn't the app's to replace")
  func signInKeepsRefusedExternalRegistration() async throws {
    let (_, _, localServer) = await makeSignedInWithLocalServer(
      registration: ServerCloudRegistration(
        connected: true,
        deviceId: "cli-device",
        state: "revoked",
        managedBy: "external"
      )
    )

    #expect(localServer.disconnects == 0)
    #expect(localServer.connects.isEmpty)
  }

  @Test("Sign-out leaves CLI-managed registrations connected")
  func signOutLeavesExternalRegistrationAlone() async throws {
    let (controller, client, localServer) = await makeSignedInWithLocalServer(
      registration: ServerCloudRegistration(
        connected: true,
        deviceId: "cli-device",
        state: "connected",
        managedBy: "external"
      )
    )

    controller.signOut()
    await controller.localRegistration.deregistrationTask?.value

    #expect(localServer.disconnects == 0)
    #expect(client.removals.isEmpty)
  }

  @Test("Sign-out without a session disconnects an app-managed machine but revokes nothing")
  func signOutWithoutSessionRevokesNothing() async {
    let (controller, client, _) = makeController()
    let localServer = FakeLocalServerClient(
      registration: ServerCloudRegistration(
        connected: true,
        deviceId: "local-device-1",
        state: "connected",
        managedBy: "app"
      )
    )
    controller.localServerClient = localServer

    controller.signOut()
    await controller.localRegistration.deregistrationTask?.value

    #expect(localServer.disconnects == 1)
    #expect(client.removals.isEmpty)
  }

  @Test("A connected registration that reports no device id is neither adopted nor replaced")
  func registrationWithoutDeviceIdIsIgnored() async {
    let client = FakeCloudClient()
    client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
    let (controller, _, store) = makeController(client: client)
    var resolved: [String] = []
    controller.onLocalMachineRegistrationResolved = { resolved.append($0) }
    let localServer = FakeLocalServerClient(
      registration: ServerCloudRegistration(connected: true, state: "connected", managedBy: "app")
    )
    controller.localServerClient = localServer
    try? store.saveToken("dev-token")

    await controller.bootstrap()
    await awaitLocalRegistration(controller)

    #expect(controller.state.isSignedIn)
    #expect(resolved.isEmpty)
    #expect(localServer.connects.isEmpty)
    #expect(localServer.disconnects == 0)
  }
}

@MainActor
func awaitLocalRegistration(_ controller: CloudAccountController) async {
  while let task = controller.localRegistration.task {
    _ = await task.value
  }
}

@MainActor
func makeSignedInWithLocalServer(
  registration: ServerCloudRegistration = ServerCloudRegistration(connected: false)
) async -> (CloudAccountController, FakeCloudClient, FakeLocalServerClient) {
  let client = FakeCloudClient()
  client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
  let (controller, _, store) = makeController(
    client: client,
    environmentCloud: CodevisorAppVariant.DevelopmentCloud(
      url: URL(string: "http://127.0.0.1:8787")!
    )
  )
  let localServer = FakeLocalServerClient(registration: registration)
  controller.localServerClient = localServer
  try? store.saveToken("dev-token")
  await controller.bootstrap()
  await awaitLocalRegistration(controller)
  return (controller, client, localServer)
}
