import CodevisorClient
import CodevisorCloud
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Sandbox machines and the profiles they came from")
struct SandboxMachineProfilesTests {
  private let owner = accountMachine("owner")
  private let studioA = accountMachine("studio-a")
  private let studioB = accountMachine("studio-b")
  private let orphan = accountMachine("orphan")
  private let ownerFake = SandboxOwnerFakeServerClient(
    sandboxes: [
      ServerSandbox(
        id: "a", vendor: "tart", name: "Tart VM a", state: "ready", profileId: "studio", deviceId: "studio-a"),
      ServerSandbox(
        id: "b", vendor: "tart", name: "Tart VM b", state: "ready", profileId: "studio", deviceId: "studio-b",
        power: "paused"),
      ServerSandbox(id: "c", vendor: "e2b", name: "E2B c", state: "ready", profileId: "deleted", deviceId: "orphan"),
    ],
    profiles: [ServerSandboxProfile(id: "studio", name: "Studio VM", vendor: "tart")]
  )

  private func makeController() -> MachineController {
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { [ownerFake] _ in ownerFake }
    )
    let provider = signIn(controller, machines: [owner, studioA, studioB, orphan])
    provider.cloudMachines = provider.cloudMachines.map(markingSandbox)
    return controller
  }

  @Test(
    "Sandboxes take their profile's current name from the Mac that owns them, and one whose profile is gone has none")
  func sandboxesResolveToProfiles() async {
    let controller = makeController()

    await controller.loadSandboxMachineProfiles()

    let studio = SandboxMachineProfile(id: "studio", name: "Studio VM", vendor: "tart")
    #expect(controller.sandboxProfile(forMachineId: studioA.id) == studio)
    #expect(controller.sandboxProfile(forMachineId: studioB.id) == studio)
    #expect(controller.sandboxProfile(forMachineId: orphan.id) == nil)
    #expect(controller.sandboxProfile(forMachineId: owner.id) == nil)
  }

  @Test("A sandbox names the Mac that owns it, so New Chat can start another from its profile there")
  func sandboxesNameTheirOwner() {
    let controller = makeController()

    #expect(controller.sandboxOwnerMachineId(forMachineId: studioA.id) == owner.id)
    #expect(controller.sandboxOwnerMachineId(forMachineId: owner.id) == nil)
  }

  @Test("An offline sandbox the owner says is paused reads as paused, and a running one as awake")
  func pausedSandboxesReadAsPaused() async {
    let controller = makeController()
    controller.markFailed(for: studioB.id, message: "offline")

    await controller.loadSandboxMachineProfiles()

    #expect(controller.sandboxPower(forMachineId: studioB.id) == SandboxMachinePower(sandboxId: "b", power: .paused))
    #expect(controller.sandboxPower(forMachineId: studioA.id) == nil)
  }

  @Test("A sandbox its owner just paused reads as paused even while it still looks connected")
  func justPausedSandboxReadsAsPaused() async {
    let controller = makeController()

    await controller.loadSandboxMachineProfiles()

    #expect(controller.availability(for: studioB.id) == .ready)
    #expect(controller.sandboxPower(forMachineId: studioB.id) == SandboxMachinePower(sandboxId: "b", power: .paused))
  }

  @Test("Waking a paused sandbox asks its owner and shows it waking right away")
  func wakingAsksTheOwner() async throws {
    let controller = makeController()
    controller.markFailed(for: studioB.id, message: "offline")
    await controller.loadSandboxMachineProfiles()

    try await controller.wakeSandbox(forMachineId: studioB.id)

    #expect(ownerFake.wokenIds == ["b"])
    #expect(controller.sandboxPower(forMachineId: studioB.id)?.power == .waking)
  }

  @Test("A refresh that can't reach the owning Mac keeps the profiles already known")
  func failedRefreshKeepsProfiles() async {
    let controller = makeController()
    await controller.loadSandboxMachineProfiles()

    ownerFake.failing = true
    await controller.loadSandboxMachineProfiles()

    #expect(controller.sandboxProfile(forMachineId: studioA.id)?.name == "Studio VM")
  }

  private func markingSandbox(_ machine: CloudMachine) -> CloudMachine {
    guard machine.deviceId != "owner" else { return machine }
    var marked = machine
    marked.ephemeral = CloudEphemeralOrigin(provider: "tart", ownerDeviceId: "owner")
    return marked
  }
}

private final class SandboxOwnerFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  let sandboxes: [ServerSandbox]
  let profiles: [ServerSandboxProfile]
  var failing = false
  var wokenIds: [String] = []

  init(sandboxes: [ServerSandbox], profiles: [ServerSandboxProfile]) {
    self.sandboxes = sandboxes
    self.profiles = profiles
  }

  func sandboxes() async throws -> [ServerSandbox] {
    if failing { throw CodevisorServerClientError.invalidResponse }
    return sandboxes
  }

  func sandboxProfiles() async throws -> [ServerSandboxProfile] {
    if failing { throw CodevisorServerClientError.invalidResponse }
    return profiles
  }

  func wakeSandbox(id: String) async throws -> ServerSandbox {
    wokenIds.append(id)
    guard let sandbox = sandboxes.first(where: { $0.id == id }) else {
      throw CodevisorServerClientError.invalidResponse
    }
    return sandbox
  }

  func info() async throws -> ServerInfo {
    ServerInfo(id: "owner", name: "Owner", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
  }
  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle")
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func latestShellEventCursor() async throws -> Int { 0 }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted { fatalError("unused") }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
