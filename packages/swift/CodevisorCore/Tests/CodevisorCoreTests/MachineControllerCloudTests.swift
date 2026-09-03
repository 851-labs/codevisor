import Foundation
import Observation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("MachineController cloud machines")
struct MachineControllerCloudTests {
  @Test("allMachines appends synthesized entries for cloud-only machines")
  func allMachinesSynthesis() throws {
    let (controller, _, provider) = makeController()
    provider.cloudMachines = [makeCloudMachine()]

    let all = controller.allMachines
    #expect(all.map(\.id) == ["local", "cloud:dev-1"])
    let cloud = try #require(all.last)
    #expect(cloud.kind == "cloud")
    #expect(cloud.isCloud)
    #expect(cloud.name == "Cloud Mac")
    #expect(cloud.baseURL == CodevisorMachine.cloudPlaceholderBaseURL)
    #expect(controller.machine(for: "cloud:dev-1") == cloud)
  }

  @Test("Cloud entries exist only while signed in")
  func signedOutHidesCloudMachines() {
    let (controller, _, provider) = makeController()
    provider.cloudMachines = [makeCloudMachine()]
    #expect(controller.allMachines.count == 2)

    provider.isCloudSignedIn = false
    #expect(controller.allMachines.map(\.id) == ["local"])
    #expect(controller.machine(for: "cloud:dev-1") == nil)
  }

  @Test("Deduplicates against configured machines by cloud device id, then name")
  func dedup() async throws {
    let deviceId = "dev-configured"
    // A real client over a canned transport, so the configured remote's
    // status probe advertises its cloud device id like a live server.
    let remoteTransport = FakeRelayRequestTransport()
    remoteTransport.responsesByPath["/v1/info"] = """
      {"id":"studio","name":"Studio","kind":"remote","version":"1.0.0",
       "platform":"darwin","bindHost":"0.0.0.0","cloudDeviceId":"\(deviceId)"}
      """
    let (controller, _, provider) = makeController(clientFactory: { machine in
      // Only the REMOTE speaks through the studio transport. Handing it
      // to every machine let a racing local probe adopt the studio's
      // cloud identity and silently corrupt deduplication.
      CodevisorServerClient(
        config: CodevisorServerConfig(
          baseURL: machine.baseURL,
          requestTransport: machine.isLocal
            ? FakeRelayRequestTransport()
            : remoteTransport,
          webSocketTransport: UnusedWebSocketTransport()
        ))
    })
    let remote = try controller.addRemote(host: "studio.tailnet.ts.net")

    provider.cloudMachines = [
      // Same identity as the configured remote (device id match after
      // its status probe answers).
      makeCloudMachine(deviceId: deviceId, name: "Studio (Cloud)"),
      // Name collision with a configured machine.
      makeCloudMachine(deviceId: "dev-name-clash", name: remote.name),
      // Genuinely cloud-only.
      makeCloudMachine(deviceId: "dev-only", name: "Only In Cloud"),
    ]

    // Before the status probe answers, the device-id duplicate is still
    // listed (name fallback doesn't match it).
    #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId, "dev-only"])

    await controller.refreshStatus(for: remote.id)
    #expect(controller.statusByMachineId[remote.id]?.cloudDeviceId == deviceId)
    #expect(controller.cloudOnlyMachines.map(\.deviceId) == ["dev-only"])
    #expect(controller.allMachines.map(\.id) == ["local", remote.id, "cloud:dev-only"])
  }

  /// A controller with one configured remote whose status probe advertises
  /// `deviceId`, plus a cloud twin of that remote on the provider — the
  /// setup for every stale-status deduplication regression below.
  private func makeDedupedRemote(
    deviceId: String
  ) async throws -> (controller: MachineController, provider: FakeCloudProvider, remote: CodevisorMachine) {
    let remoteTransport = FakeRelayRequestTransport()
    remoteTransport.responsesByPath["/v1/info"] = """
      {"id":"studio","name":"Studio","kind":"remote","version":"1.0.0",
       "platform":"darwin","bindHost":"0.0.0.0","cloudDeviceId":"\(deviceId)"}
      """
    let (controller, _, provider) = makeController(clientFactory: { machine in
      // Only the REMOTE speaks through the studio transport. Handing it
      // to every machine let a racing local probe adopt the studio's
      // cloud identity and silently corrupt deduplication.
      CodevisorServerClient(
        config: CodevisorServerConfig(
          baseURL: machine.baseURL,
          requestTransport: machine.isLocal
            ? FakeRelayRequestTransport()
            : remoteTransport,
          webSocketTransport: UnusedWebSocketTransport()
        ))
    })
    let remote = try controller.addRemote(host: "studio.tailnet.ts.net")
    await controller.refreshStatus(for: remote.id)
    provider.cloudMachines = [makeCloudMachine(deviceId: deviceId, name: "Studio (Cloud)")]
    #expect(controller.cloudOnlyMachines.isEmpty)
    return (controller, provider, remote)
  }

  @Test("Removing a machine frees its cloud twin for the unified list")
  func removedMachineStatusDoesNotDeduplicate() async throws {
    let deviceId = "dev-removed"
    let (controller, _, remote) = try await makeDedupedRemote(deviceId: deviceId)

    try controller.removeMachine(remote.id)

    #expect(controller.statusByMachineId[remote.id] == nil)
    #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId])
    #expect(controller.allMachines.map(\.id) == ["local", "cloud:\(deviceId)"])
  }

  @Test("The delete-all-data reset frees cloud twins of removed machines")
  func resetFreesCloudTwins() async throws {
    // The exact post-reset regression: "reset app data" runs in-process
    // (removeAllRemoteMachines), so without pruning, the removed dev
    // remote's stale status kept hiding its cloud entry after the user
    // re-onboarded and signed back in.
    let deviceId = "dev-reset"
    let (controller, _, _) = try await makeDedupedRemote(deviceId: deviceId)

    controller.removeAllRemoteMachines()

    #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId])
    #expect(controller.allMachines.map(\.id) == ["local", "cloud:\(deviceId)"])
  }

  @Test("A status probe landing after removal still doesn't hide the twin")
  func lateProbeAfterRemovalDoesNotDeduplicate() async throws {
    // An in-flight refreshStatus can re-create the removed machine's
    // status entry after removal pruned it. Deduplication must only count
    // statuses of currently configured machines, so even that stale entry
    // cannot hide the cloud twin.
    let deviceId = "dev-late-probe"
    let (controller, _, remote) = try await makeDedupedRemote(deviceId: deviceId)

    try controller.removeMachine(remote.id)
    // An in-flight refreshStatus holds its pre-removal client and its
    // result can land after removal pruned the entry — model the landing
    // directly rather than through client re-resolution, which correctly
    // refuses to dial a machine that no longer exists.
    controller.connection(for: remote.id).status = MachineStatus(
      isReachable: true,
      label: "Studio 1.0.0",
      cloudDeviceId: deviceId,
      route: .direct,
      serverId: "studio"
    )

    #expect(controller.statusByMachineId[remote.id]?.cloudDeviceId == deviceId)
    #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId])
  }

  @Test("A configured machine's probe prunes records under its cloud twin id")
  func probePrunesCloudTwinRecords() async throws {
    let deviceId = "dev-twin"
    let remoteTransport = FakeRelayRequestTransport()
    remoteTransport.responsesByPath["/v1/info"] = """
      {"id":"studio","name":"Studio","kind":"remote","version":"1.0.0",
       "platform":"darwin","bindHost":"0.0.0.0","cloudDeviceId":"\(deviceId)"}
      """
    let (controller, projectList, provider) = makeController(clientFactory: { machine in
      CodevisorServerClient(
        config: CodevisorServerConfig(
          baseURL: machine.baseURL,
          requestTransport: remoteTransport,
          webSocketTransport: UnusedWebSocketTransport()
        ))
    })
    let remote = try controller.addRemote(host: "studio.tailnet.ts.net")
    provider.cloudMachines = [makeCloudMachine(deviceId: deviceId, name: "Studio (Cloud)")]

    // Records that synced under the twin id before the probe landed.
    let twinId = "cloud:\(deviceId)"
    let twinProject = Project.fromFolder(
      URL(fileURLWithPath: "/srv/studio-work"),
      serverId: twinId
    )
    projectList.projects.append(twinProject)
    projectList.sessions.append(
      ChatSession(projectId: twinProject.id, serverId: twinId, title: "twin chat")
    )

    await controller.refreshStatus(for: remote.id)

    // The twin's records are gone, and connecting to the twin is refused.
    #expect(!projectList.projects.contains { $0.serverId == twinId })
    #expect(!projectList.sessions.contains { $0.serverId == twinId })
    #expect(controller.canonicalComposerMachineId(for: twinId) == remote.id)
  }

  @Test("A resolved local registration removes its cloud twin before fleet sync")
  func resolvedLocalRegistrationPrunesTwin() {
    let deviceId = "local-device"
    let twinId = "cloud:\(deviceId)"
    let (controller, projectList, provider) = makeController()
    provider.cloudMachines = [
      makeCloudMachine(deviceId: deviceId, name: "Local Through Cloud")
    ]
    let twinProject = Project.fromFolder(
      URL(fileURLWithPath: "/srv/local-work"),
      serverId: twinId
    )
    projectList.projects.append(twinProject)
    projectList.sessions.append(
      ChatSession(projectId: twinProject.id, serverId: twinId, title: "duplicate")
    )

    controller.adoptLocalCloudIdentity(deviceId: deviceId)

    #expect(controller.statusByMachineId["local"]?.cloudDeviceId == deviceId)
    #expect(controller.allMachines.map(\.id) == ["local"])
    #expect(!projectList.projects.contains { $0.serverId == twinId })
    #expect(!projectList.sessions.contains { $0.serverId == twinId })
  }

}

extension MachineControllerCloudTests {
  @Test("An in-flight cloud twin snapshot cannot resurrect pruned records")
  func inFlightTwinSnapshotCannotResurrectRecords() async throws {
    let deviceId = "dev-racing-twin"
    let twinId = "cloud:\(deviceId)"
    let projectId = UUID()
    let sessionId = UUID()
    let local = SyncFakeServerClient(projects: [], sessions: [])
    local.configureInfoId("local")
    local.configureInfoCloudDeviceId(deviceId)
    let (controller, projectList, provider) = makeController(clientFactory: { _ in local })
    provider.cloudMachines = [makeCloudMachine(deviceId: deviceId, name: "Local (Cloud)")]
    provider.requestTransport.responsesByPath["/v1/info"] = """
      {"id":"local","name":"Local","kind":"local","version":"0.1.0",
       "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"\(deviceId)"}
      """
    provider.requestTransport.responsesByPath["/v1/events/cursor"] = #"{"cursor":0}"#
    provider.requestTransport.responsesByPath["/v1/projects"] = """
      [{"id":"\(projectId.uuidString)","name":"racing-twin","isArchived":false,
        "origin":"codevisor","createdAt":"2026-06-30T00:00:00.000Z",
        "locations":[{"id":"loc-1","projectId":"\(projectId.uuidString)",
          "serverId":"local","folderPath":"/srv/racing-twin",
          "createdAt":"2026-06-30T00:00:00.000Z","isGitRepository":false}]}]
      """
    provider.requestTransport.responsesByPath["/v1/sessions"] = """
      [{"id":"\(sessionId.uuidString)","projectId":"\(projectId.uuidString)",
        "serverId":"local","harnessId":"codex","agentSessionId":null,
        "title":"racing twin chat","origin":"codevisor","isArchived":false,
        "createdAt":"2026-06-30T00:00:01.000Z",
        "updatedAt":"2026-06-30T00:00:02.000Z","usage":null}]
      """
    provider.requestTransport.delaysByPath["/v1/sessions"] = 250_000_000
    var connectedMachineIds: [String] = []
    controller.onMachineConnected = { connectedMachineIds.append($0) }

    // Let the twin pass its status probe and enter the authoritative list
    // fetch. The configured local probe then discovers both ids are the
    // same device and prunes the twin while that fetch is suspended.
    let connect = Task { await controller.connectMachine(twinId) }
    for _ in 0..<100 {
      if provider.requestTransport.requestCount(for: "/v1/sessions") > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(provider.requestTransport.requestCount(for: "/v1/sessions") == 1)

    await controller.refreshStatus(for: "local")
    await connect.value

    #expect(!projectList.projects.contains { $0.serverId == twinId })
    #expect(!projectList.sessions.contains { $0.serverId == twinId })
    #expect(controller.statusByMachineId[twinId] == nil)
    #expect(!connectedMachineIds.contains(twinId))
    #expect(controller.allMachines.map(\.id) == ["local"])
  }

}

extension MachineControllerCloudTests {
  @Test("Dead cloud identities' records are pruned after a roster refresh")
  func deadCloudRecordPrune() throws {
    let (controller, projectList, provider) = makeController()
    // Live machine dev-1; dev-gone was wiped and re-registered long ago.
    provider.cloudMachines = [makeCloudMachine(deviceId: "dev-1")]
    let liveId = "cloud:dev-1"
    let deadId = "cloud:dev-gone"
    for serverId in [liveId, deadId] {
      let project = Project.fromFolder(
        URL(fileURLWithPath: "/srv/\(serverId)"),
        serverId: serverId
      )
      projectList.projects.append(project)
      projectList.sessions.append(
        ChatSession(projectId: project.id, serverId: serverId, title: "chat")
      )
    }

    controller.pruneDeadCloudRecords()

    // Only the identity absent from the fetched roster is gone.
    #expect(!projectList.projects.contains { $0.serverId == deadId })
    #expect(!projectList.sessions.contains { $0.serverId == deadId })
    #expect(projectList.projects.contains { $0.serverId == liveId })
    #expect(projectList.sessions.contains { $0.serverId == liveId })

    // Signed out: the roster is unknown, not empty — nothing is pruned.
    provider.isCloudSignedIn = false
    provider.cloudMachines = []
    controller.pruneDeadCloudRecords()
    #expect(projectList.projects.contains { $0.serverId == liveId })
  }

  @Test("Selecting a cloud machine persists and yields a relay-backed client")
  func cloudSelection() async throws {
    let store = InMemoryStore()
    let (controller, projectList, provider) = makeController(store: store)
    provider.cloudMachines = [makeCloudMachine()]
    provider.requestTransport.responsesByPath["/v1/info"] = """
      {"id":"m1","name":"Cloud Mac","kind":"remote","version":"2.0.0",
       "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"dev-1"}
      """

    controller.selectMachine("cloud:dev-1")
    #expect(controller.selectedMachineId == "cloud:dev-1")
    #expect(controller.selectedMachine.isCloud)
    #expect(projectList.selectedServerId == "local")

    // The client is a real CodevisorServerClient tunneling through the
    // provider's relay transports.
    let info = try await controller.client(for: "cloud:dev-1").info()
    #expect(info.name == "Cloud Mac")
    #expect(provider.configRequests.contains("dev-1"))
    #expect(provider.requestTransport.paths.contains("/v1/info"))

    // refreshStatus flows through the same relay client.
    await controller.refreshStatus(for: "cloud:dev-1")
    #expect(controller.statusByMachineId["cloud:dev-1"]?.isReachable == true)
    #expect(controller.statusByMachineId["cloud:dev-1"]?.cloudDeviceId == "dev-1")

    // The selection persists (the id is stable across launches).
    let persisted = try JSONDecoder().decode(
      MachineRegistry.self,
      from: #require(store.loadData(forKey: "machines"))
    )
    #expect(persisted.selectedMachineId == "cloud:dev-1")
  }

  @Test("A cloud id with no relay yields a failing client, never the local machine's")
  func unresolvedCloudIdNeverFallsBackToLocal() async {
    let (controller, _, provider) = makeController()
    // The launch-time gap: the account looks signed out (or the roster
    // hasn't loaded), so no relay config exists for the id yet. Falling
    // back to the local client here once served the LOCAL harness
    // catalog for a cloud machine — which the capability cache then
    // persisted under the cloud machine's key.
    provider.isCloudSignedIn = false
    let client = controller.client(for: "cloud:dev-1")
    await #expect(throws: MachineUnreachableError.self) {
      _ = try await client.capabilities(cwd: "/tmp")
    }

    // Once the roster lands, the same id resolves to the relay client.
    provider.isCloudSignedIn = true
    provider.cloudMachines = [makeCloudMachine()]
    provider.requestTransport.responsesByPath["/v1/info"] = """
      {"id":"m1","name":"Cloud Mac","kind":"remote","version":"2.0.0",
       "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"dev-1"}
      """
    let reachable = controller.client(for: "cloud:dev-1")
    let info = try? await reachable.info()
    #expect(info?.name == "Cloud Mac")
  }

  @Test("serverConfig(for:) is relay-backed for cloud ids, plain otherwise")
  func serverConfigRouting() {
    let (controller, _, provider) = makeController()
    provider.cloudMachines = [makeCloudMachine()]

    let cloudConfig = controller.serverConfig(for: "cloud:dev-1")
    #expect(cloudConfig.requestTransport != nil)
    #expect(cloudConfig.webSocketTransport != nil)
    #expect(cloudConfig.baseURL == CodevisorMachine.cloudPlaceholderBaseURL)

    let localConfig = controller.serverConfig(for: "local")
    #expect(localConfig.requestTransport == nil)
    #expect(localConfig.baseURL == CodevisorMachine.local.baseURL)
  }

  @Test("A listening loopback bridge replaces the placeholder baseURL")
  func loopbackBaseURLSynthesis() throws {
    let (controller, _, provider) = makeController()
    provider.cloudMachines = [makeCloudMachine()]

    // Before the bridge is up: placeholder everywhere.
    #expect(
      controller.machine(for: "cloud:dev-1")?.baseURL
        == CodevisorMachine.cloudPlaceholderBaseURL
    )

    // Once the bridge listens, baseURL consumers (the external terminal
    // proxy reads machine.baseURL / serverConfig.baseURL) get the real
    // loopback address.
    let loopback = URL(string: "http://127.0.0.1:54321")!
    provider.loopbackURLsByDeviceId["dev-1"] = loopback
    #expect(controller.machine(for: "cloud:dev-1")?.baseURL == loopback)
    #expect(controller.serverConfig(for: "cloud:dev-1").baseURL == loopback)
    // The relay transports stay attached — the loopback URL is for
    // external processes, in-app clients keep tunneling in-process.
    #expect(controller.serverConfig(for: "cloud:dev-1").requestTransport != nil)
  }

  @Test("Registries persisted before explicit selection decode")
  func registryDecodeCompatibility() throws {
    let legacy = """
      {"selectedMachineId":"local","remoteMachines":[]}
      """
    let registry = try JSONDecoder().decode(MachineRegistry.self, from: Data(legacy.utf8))
    #expect(registry.selectedMachineId == "local")
    #expect(!registry.hasExplicitMachineSelection)
  }

  @Test("Sign-out with a cloud machine selected falls back to local")
  func signOutFallsBackToLocal() {
    let (controller, projectList, provider) = makeController()
    provider.cloudMachines = [makeCloudMachine()]
    controller.selectMachine("cloud:dev-1")
    #expect(controller.selectedMachineId == "cloud:dev-1")

    provider.isCloudSignedIn = false
    controller.handleCloudAccountSignedOut()
    #expect(controller.selectedMachineId == "local")
    #expect(controller.selectedMachine == .local)
    #expect(projectList.selectedServerId == "local")
  }

  @Test("A cloud machine arriving with no explicit selection is auto-selected")
  func autoSelectsCloudMachineWhenNoExplicitChoice() async throws {
    let store = InMemoryStore()
    let (controller, projectList, provider) = makeController(store: store, localServer: nil)
    provider.requestTransport.responsesByPath["/v1/info"] = """
      {"id":"m1","name":"Dev Remote","kind":"remote","version":"2.0.0",
       "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"dev-1"}
      """
    // Fresh registry: local placeholder selected, no explicit choice.
    #expect(controller.selectedMachineId == "local")
    #expect(controller.registry.hasExplicitMachineSelection == false)

    provider.cloudMachines = [makeCloudMachine()]
    controller.reconcileCloudSelection()

    #expect(controller.selectedMachine.isCloud)
    #expect(controller.selectedMachineId == "cloud:dev-1")
    #expect(projectList.selectedServerId == "local")
    // Auto-selection must NOT masquerade as an explicit choice.
    #expect(controller.registry.hasExplicitMachineSelection == false)
    // Explicit preparation connects through the relay client.
    await controller.prepareMachine(controller.selectedMachineId)
    #expect(provider.configRequests.contains("dev-1"))
    #expect(provider.requestTransport.paths.contains("/v1/info"))

    // The auto-selection persists so a relaunch resolves the same machine.
    let persisted = try JSONDecoder().decode(
      MachineRegistry.self,
      from: #require(store.loadData(forKey: "machines"))
    )
    #expect(persisted.selectedMachineId == "cloud:dev-1")
    #expect(persisted.hasExplicitMachineSelection == false)
  }

  @Test("A client-only platform never strands even an explicit local selection")
  func strandedLocalSelectionIsRescued() throws {
    // Legacy persisted state: "local" was explicitly selected back when
    // this platform still listed it. Client-only platforms have no
    // "Local" machine, so the choice cannot bind — an arriving real
    // machine is adopted instead of stranding the user on an unreachable
    // fleet.
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(
        MachineRegistry(
          selectedMachineId: "local",
          hasExplicitMachineSelection: true,
          remoteMachines: []
        )
      ),
      forKey: "machines"
    )
    let (controller, projectList, provider) = makeController(store: store, localServer: nil)
    #expect(controller.registry.hasExplicitMachineSelection)

    provider.cloudMachines = [makeCloudMachine()]
    controller.reconcileCloudSelection()

    #expect(controller.selectedMachineId == "cloud:dev-1")
    #expect(projectList.selectedServerId == "local")
  }

  @Test("A working local server remains the default when cloud machines arrive")
  func localServerRemainsDefault() {
    let (controller, projectList, provider) = makeController(
      localServer: StubLocalServer()
    )
    #expect(controller.registry.hasExplicitMachineSelection == false)

    provider.cloudMachines = [makeCloudMachine()]
    controller.reconcileCloudSelection()

    #expect(controller.selectedMachineId == "local")
    #expect(projectList.selectedServerId == "local")
    #expect(controller.registry.hasExplicitMachineSelection == false)
  }

  @Test("Auto-selection prefers an online machine over list order")
  func autoSelectPrefersOnlineMachine() {
    let (controller, _, provider) = makeController(localServer: nil)
    // Offline machine first in list order, online machine second.
    provider.cloudMachines = [
      makeCloudMachine(deviceId: "dev-offline", name: "Offline Mac", online: false),
      makeCloudMachine(deviceId: "dev-online", name: "Online Mac", online: true),
    ]
    controller.reconcileCloudSelection()

    // Online preference beats list order.
    #expect(controller.selectedMachineId == "cloud:dev-online")
  }

  @Test("Auto-selection falls back to list order when no machine is online")
  func autoSelectFallsBackToListOrderWhenAllOffline() {
    let (controller, _, provider) = makeController(localServer: nil)
    provider.cloudMachines = [
      makeCloudMachine(deviceId: "dev-a", name: "A Mac", online: false),
      makeCloudMachine(deviceId: "dev-b", name: "B Mac", online: false),
    ]
    controller.reconcileCloudSelection()

    // No online candidate: the first in list order wins.
    #expect(controller.selectedMachineId == "cloud:dev-a")
  }

  @Test("With no machines at all, a client-only platform stays on the placeholder")
  func autoSelectStaysLocalWithNoOtherMachines() {
    let (controller, projectList, _) = makeController(localServer: nil)
    // No cloud machines, no remotes: nothing to prefer over local.
    controller.reconcileCloudSelection()

    #expect(controller.selectedMachineId == "local")
    #expect(projectList.selectedServerId == "local")
    #expect(controller.registry.hasExplicitMachineSelection == false)
  }

  @Test("Registries persisted before hasExplicitMachineSelection decode to false")
  func registryDecodesExplicitFlagCompat() throws {
    let legacy = """
      {"selectedMachineId":"local","remoteMachines":[]}
      """
    let registry = try JSONDecoder().decode(MachineRegistry.self, from: Data(legacy.utf8))
    #expect(registry.hasExplicitMachineSelection == false)
  }

  @Test("A persisted cloud selection resolves to local until the account arrives")
  func persistedCloudSelectionFallsBackWhileSignedOut() {
    let store = InMemoryStore()
    let first = makeController(store: store)
    first.provider.cloudMachines = [makeCloudMachine()]
    first.controller.selectMachine("cloud:dev-1")

    // Relaunch without a provider: selection stays persisted, but the
    // resolved machine is local.
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let second = MachineController(store: store, projectList: projectList)
    #expect(second.selectedMachineId == "cloud:dev-1")
    #expect(second.selectedMachine == .local)

    // Once the account's machines arrive, reconciliation rewires the
    // selection to the now-available cloud machine.
    let provider = FakeCloudProvider()
    provider.cloudMachines = [makeCloudMachine()]
    second.cloudProvider = provider
    second.reconcileCloudSelection()
    #expect(second.selectedMachine.isCloud)
    #expect(projectList.selectedServerId == "local")
  }

  @Test("effectiveHTTPBaseURL waits for a cloud machine's loopback bridge")
  func effectiveBaseURLCloudMachineWaitsForBridge() async {
    let (controller, _, provider) = makeController()
    let cloud = makeCloudMachine()
    provider.cloudMachines = [cloud]

    // The bridge publishes its port a beat after the first touch, like
    // CloudAccountController does once the listener is up.
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(50))
      provider.loopbackURLsByDeviceId[cloud.deviceId] = URL(string: "http://127.0.0.1:50505")!
    }
    let url = await controller.effectiveHTTPBaseURL(forMachineId: "cloud:dev-1")
    #expect(url == URL(string: "http://127.0.0.1:50505"))
  }

  @Test("effectiveHTTPBaseURL gives up when the bridge never comes up")
  func effectiveBaseURLCloudMachineTimesOut() async {
    let (controller, _, provider) = makeController()
    provider.cloudMachines = [makeCloudMachine()]

    let url = await controller.effectiveHTTPBaseURL(
      forMachineId: "cloud:dev-1",
      timeout: .milliseconds(150)
    )
    #expect(url == nil)
  }
}

@MainActor
@Observable
final class StubLocalServer: LocalServerControlling {
  var state: LocalCodevisorServerState = .idle
  var dataUpgradeProgress: LocalDataUpgradeProgress?
  var onUpdateRequested: (@MainActor () -> Void)?

  func configureManagedService(_ service: LocalCodevisorManagedService) {}
  func ensureRunning() async -> LocalCodevisorServerState { state }
  func prepareForAppUpdate(onStatus: @escaping @MainActor (String) -> Void) async -> Bool { true }
  func abandonAppUpdate() async {}
  func shutdown() async -> Bool { true }
  func requestSafeModeOnNextLaunch() {}
}
