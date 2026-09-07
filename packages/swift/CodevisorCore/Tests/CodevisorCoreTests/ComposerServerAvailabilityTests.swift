import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Composer server availability")
struct ComposerServerAvailabilityTests {
  @Test(
    "An unavailable target keeps its draft and rejects prompt and goal submission",
    arguments: [ServerAvailability.waiting(.connecting), .failed("Offline"), .waiting(.restarting)])
  func unavailableTargetPreservesDraft(availability: ServerAvailability) async {
    let fixture = Fixture()
    let controller = fixture.controller
    fixture.machines.connection(for: "macbook").availability = availability
    fixture.machines.markReady(for: "studio")
    controller.composerText = "Continue my work"
    var accepted = false
    controller.onFirstSend = { _ in accepted = true }

    #expect(!controller.canSend)
    await controller.send()
    controller.isGoalComposerArmed = true
    await controller.submitGoalFromComposer()

    #expect(!accepted)
    #expect(controller.composerText == "Continue my work")
    #expect(controller.isGoalComposerArmed)
    #expect(!controller.hasAcceptedFirstSend)
    #expect(controller.pendingUserMessage == nil)
  }

  @Test("Switching to a ready machine enables the same draft while the old machine stays offline")
  func switchToReadyMachine() async {
    let fixture = Fixture()
    fixture.machines.markFailed(for: "macbook", message: "Offline")
    fixture.machines.markReady(for: "studio")
    fixture.controller.composerText = "Use the Studio"

    await fixture.controller.retarget(
      to: .runTargetPlaceholder(serverId: "studio"),
      serverClient: fixture.client
    )

    #expect(fixture.controller.canSend)
    #expect(fixture.controller.composerText == "Use the Studio")
    #expect(fixture.controller.project.serverId == "studio")
    fixture.machines.beginWaiting(for: "macbook", reason: .connecting)
    #expect(fixture.controller.canSend)
    fixture.machines.beginWaiting(for: "studio", reason: .connecting)
    #expect(!fixture.controller.canSend)
    fixture.machines.markReady(for: "studio")
    #expect(fixture.controller.canSend)
  }

  @Test("A cached target is unavailable until its connection has been prepared")
  func unknownAvailabilityDoesNotPermitSend() {
    let fixture = Fixture()
    fixture.controller.composerText = "Wait for discovery"
    #expect(fixture.controller.selectedHarness != nil)
    #expect(!fixture.controller.canSend)
    #expect(fixture.controller.serverAvailability == .waiting(.connecting))
  }

  @Test("A route change on the original machine cannot redirect a retargeted draft")
  func routeChangeUsesCurrentTarget() async {
    let fixture = Fixture()
    fixture.machines.markReady(for: "studio")
    await fixture.controller.retarget(
      to: .runTargetPlaceholder(serverId: "studio"), serverClient: fixture.client
    )
    let replacement = SyncFakeServerClient(projects: [], sessions: [])

    fixture.controller.adoptServerClient(replacement, forServer: "macbook")
    #expect(fixture.controller.serverClient as? SyncFakeServerClient === fixture.client)
    fixture.controller.adoptServerClient(replacement, forServer: "studio")
    #expect(fixture.controller.serverClient as? SyncFakeServerClient === replacement)
  }

  @Test(
    "A late response from the old machine cannot replace the chosen machine's capabilities",
    arguments: [false, true])
  func pendingPreparationDoesNotBlockSwitch(oldRequestFails: Bool) async {
    let fixture = Fixture()
    let gate = FetchGate()
    let oldClient = SyncFakeServerClient(projects: [], sessions: [])
    let oldCapability = Self.capability(id: "old-harness")
    oldClient.capabilitiesHandler = { _ in
      await gate.wait()
      if oldRequestFails { throw CodevisorServerClientError.invalidResponse }
      return ServerCapabilities(harnesses: [oldCapability])
    }
    fixture.machines.markReady(for: "macbook")
    fixture.machines.markReady(for: "studio")
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: "macbook"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: oldClient,
      machines: fixture.machines
    )
    controller.composerText = "Keep this draft"
    let preparation = Task { await controller.prepare() }
    await gate.awaitWaiter()
    fixture.machines.markFailed(for: "macbook", message: "Disconnected")

    await controller.retarget(
      to: .runTargetPlaceholder(serverId: "studio"), serverClient: fixture.client
    )
    #expect(controller.canSend)
    #expect(controller.selectedHarnessId == "codex")
    await gate.release()
    await preparation.value

    #expect(controller.project.serverId == "studio")
    #expect(controller.selectedHarnessId == "codex")
    #expect(controller.composerText == "Keep this draft")
    #expect(controller.canSend)
  }

  @Test("An offline draft can prepare when its own machine recovers")
  func prepareAfterRecovery() async {
    let fixture = Fixture()
    fixture.controller.harnesses = []
    fixture.controller.selectedHarnessId = nil
    fixture.controller.composerText = "Resume when connected"
    fixture.client.capabilitiesHandler = { _ in
      Issue.record("An unavailable machine must not be queried")
      return ServerCapabilities(harnesses: [])
    }
    await fixture.controller.prepare()
    #expect(!fixture.controller.canSend)

    let capability = Self.capability()
    fixture.client.capabilitiesHandler = { _ in ServerCapabilities(harnesses: [capability]) }
    fixture.machines.markReady(for: "macbook")
    await fixture.controller.prepare()

    #expect(fixture.controller.canSend)
    #expect(fixture.controller.selectedHarnessId == "codex")
    #expect(fixture.controller.composerText == "Resume when connected")
  }

  private static func capability(id: String = "codex") -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: ServerHarness(
        id: id, name: id, symbolName: "sparkle", source: "registry",
        launchKind: "executable", enabled: true,
        readiness: ServerHarnessReadiness(state: "ready")
      ),
      configOptions: []
    )
  }

  @MainActor
  private struct Fixture {
    let client: SyncFakeServerClient
    let machines: MachineController
    let controller: SessionController

    init() {
      client = SyncFakeServerClient(projects: [], sessions: [])
      let capability = ComposerServerAvailabilityTests.capability()
      client.capabilitiesHandler = { _ in ServerCapabilities(harnesses: [capability]) }
      let store = InMemoryStore()
      machines = MachineController(
        store: store,
        projectList: ProjectListModel(
          projectRepository: DefaultProjectRepository(store: store),
          sessionRepository: DefaultSessionRepository(store: store)
        ),
        clientFactory: { [client] _ in client }
      )
      controller = SessionController(
        project: .runTargetPlaceholder(serverId: "macbook"),
        configCache: ConfigOptionCache(store: InMemoryStore()),
        serverClient: client,
        machines: machines
      )
      controller.harnesses = [capability.harness]
      controller.selectedHarnessId = capability.harness.id
    }
  }
}
