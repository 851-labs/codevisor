import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Machine reachability recovery")
struct MachineReachabilityRecoveryTests {
  private func chat(
    on machines: MachineController, machineId: String
  ) -> SessionController {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: machineId),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client,
      machines: machines
    )
    controller.model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    return controller
  }

  @Test("A chat whose machine fails just says it's reconnecting, through retries, and clears once it's back")
  func chatReportsAnUnreachableMachine() async {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let (machines, _, _) = makeController(localServer: nil, reconnectNoticeScheduler: clock.scheduler)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    machines.markReady(for: studio.id)
    let controller = chat(on: machines, machineId: studio.id)
    #expect(controller.connectionRecoveryMessage == nil)

    machines.markFailed(for: studio.id, message: "Offline")
    #expect(controller.connectionRecoveryMessage == nil)
    await awaitObserved { clock.pendingCount == 1 }
    clock.advance()
    await awaitObserved { controller.connectionRecoveryMessage == "Reconnecting…" }

    machines.beginWaiting(for: studio.id, reason: .connecting)
    machines.markFailed(for: studio.id, message: "Offline")
    #expect(controller.connectionRecoveryMessage == "Reconnecting…")

    machines.markReady(for: studio.id)
    #expect(controller.connectionRecoveryMessage == "Reconnecting…")
    await awaitObserved { clock.pendingCount == 1 }
    clock.advance()
    await awaitObserved { controller.connectionRecoveryMessage == nil }
  }

  @Test("A machine that answers again within a blip never makes its chats say Reconnecting")
  func briefMachineWaitStaysQuiet() async {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let (machines, _, _) = makeController(localServer: nil, reconnectNoticeScheduler: clock.scheduler)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    machines.markReady(for: studio.id)
    let controller = chat(on: machines, machineId: studio.id)

    machines.beginWaiting(for: studio.id, reason: .connecting)
    #expect(controller.connectionRecoveryMessage == nil)
    machines.markReady(for: studio.id)
    #expect(controller.connectionRecoveryMessage == nil)

    machines.beginWaiting(for: studio.id, reason: .connecting)
    await awaitObserved { clock.pendingCount == 1 }
    #expect(clock.requestedIntervals.last == .seconds(5))
    clock.advance()
    await awaitObserved { controller.connectionRecoveryMessage == "Reconnecting…" }
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
