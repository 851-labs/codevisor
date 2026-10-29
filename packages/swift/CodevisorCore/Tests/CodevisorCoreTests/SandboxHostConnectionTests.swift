import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("The Mac that answers for a sandbox profile")
struct SandboxHostConnectionTests {
  @Test("This Mac's server that is still starting is checked later, even before it reports its id")
  func startingLocalServer() {
    let machines = makeMachines()
    machines.connection(for: CodevisorMachine.local.id).status = nil
    machines.beginWaiting(for: CodevisorMachine.local.id, reason: .starting)
    #expect(kind(machines.sandboxHostConnection(forServerId: "server-local")) == "starting")

    machines.connection(for: CodevisorMachine.local.id).status = status(serverId: "server-local")
    #expect(kind(machines.sandboxHostConnection(forServerId: "server-local")) == "starting")
  }

  @Test("This Mac's server that is up but hasn't reported its id is checked again once it does")
  func unidentifiedLocalServer() {
    let machines = makeMachines()
    machines.connection(for: CodevisorMachine.local.id).status = nil
    let before = machines.sandboxProfilesLoadKey(composerId: "local")
    #expect(kind(machines.sandboxHostConnection(forServerId: "server-local")) == "starting")

    machines.connection(for: CodevisorMachine.local.id).status = status(serverId: "server-local")

    #expect(kind(machines.sandboxHostConnection(forServerId: "server-local")) == "ready")
    #expect(machines.sandboxProfilesLoadKey(composerId: "local") != before)
  }

  @Test("A remote Mac that isn't ready, or this Mac's server that failed to start, isn't connected")
  func unreachableHosts() {
    let machines = makeMachines()
    machines.beginWaiting(for: "cloud:studio", reason: .connecting)
    machines.markFailed(for: CodevisorMachine.local.id, message: "Codevisor couldn't start")

    #expect(kind(machines.sandboxHostConnection(forServerId: "server-studio")) == "unreachable")
    #expect(kind(machines.sandboxHostConnection(forServerId: "server-local")) == "unreachable")
  }

  @Test("Ready Macs answer, and an unknown server isn't connected once this Mac is up")
  func readyHosts() {
    let machines = makeMachines()

    #expect(kind(machines.sandboxHostConnection(forServerId: "server-local")) == "ready")
    #expect(kind(machines.sandboxHostConnection(forServerId: "server-studio")) == "ready")
    #expect(kind(machines.sandboxHostConnection(forServerId: "server-gone")) == "unreachable")
  }

  private func makeMachines() -> MachineController {
    let machines = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    signIn(machines, machines: [accountMachine("studio")])
    machines.markReady(for: CodevisorMachine.local.id)
    machines.connection(for: CodevisorMachine.local.id).status = status(serverId: "server-local")
    machines.connection(for: "cloud:studio").status = status(serverId: "server-studio")
    return machines
  }

  private func status(serverId: String) -> MachineStatus {
    MachineStatus(isReachable: true, label: serverId, serverId: serverId)
  }

  private func kind(_ host: SandboxHostConnection) -> String {
    switch host {
    case .ready: "ready"
    case .starting: "starting"
    case .unreachable: "unreachable"
    }
  }
}
