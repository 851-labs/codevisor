import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Connection loss is the app's to manage: a chat only reports it in its
/// ephemeral activity line, and the app recovers without any user action.
@MainActor
@Suite("Machine reachability recovery")
struct MachineReachabilityRecoveryTests {
  @Test("A chat says its machine can't be reached while it has failed, and clears once it's back")
  func chatReportsAnUnreachableMachine() {
    let (machines, _, _) = makeController(localServer: nil)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: studio.id),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client,
      machines: machines
    )
    controller.model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    #expect(controller.connectionRecoveryMessage == nil)

    machines.markFailed(for: studio.id, message: "Offline")
    #expect(controller.connectionRecoveryMessage == "Unable to connect to Mac Studio…")

    machines.beginWaiting(for: studio.id, reason: .connecting)
    #expect(controller.connectionRecoveryMessage == "Reconnecting…")

    machines.markReady(for: studio.id)
    #expect(controller.connectionRecoveryMessage == nil)
  }

  @Test("A failed machine is prepared as soon as its tunnel is back, not at its next scheduled retry")
  func tunnelReturnRecoversAFailedMachine() async {
    let (machines, _, _) = makeController(localServer: nil)
    let studio = accountMachine("studio", name: "Mac Studio")
    let provider = signIn(machines, machines: [studio])
    provider.requestTransport.responsesByPath["/v1/info"] = """
      {"id":"studio","name":"Mac Studio","kind":"remote","version":"1.0.0",
       "platform":"darwin","bindHost":"127.0.0.1"}
      """
    machines.markFailed(for: studio.id, message: "Offline")

    machines.cloudMachineBecameReachable(deviceId: "studio")

    await awaitObserved { machines.availability(for: studio.id) == .ready }
    #expect(provider.requestTransport.requestCount(for: "/v1/info") >= 1)
  }
}
