import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Plugin settings machine routing")
struct PluginSettingsSessionTests {
  @Test("An iPhone with no machines cannot open a flow against the local placeholder")
  func noLocalTarget() {
    let (machines, _, _) = makeController(localServer: nil)

    #expect(PluginSettingsSession.availableMachines(in: machines).isEmpty)
    #expect(PluginSettingsSession(machines: machines, machineId: "local", page: .browse) == nil)
    #expect(PluginSettingsSession(machines: machines, machineId: "local", page: .install(initialSource: nil)) == nil)
  }

  @Test("An iPhone browses its cloud machine before legacy selection has caught up")
  func browseCloudMachine() async throws {
    let (machines, _, provider) = makeController(localServer: nil)
    provider.cloudMachines = [makeCloudMachine()]
    configurePlugins(provider)
    #expect(machines.selectedMachineId == "local")
    #expect(PluginSettingsSession.availableMachines(in: machines).map(\.id) == ["cloud:dev-1"])
    let session = try #require(PluginSettingsSession(machines: machines, machineId: "cloud:dev-1", page: .browse))

    let registry = try await session.fetchRegistry()

    #expect(registry.entries.map(\.id) == ["owner.plugin"])
    #expect(session.installedIds == ["owner.plugin"])
    #expect(provider.requestTransport.paths == ["/v1/plugins/registry", "/v1/plugins"])
    #expect(provider.configRequests == ["dev-1", "dev-1"])
  }

  @Test("Offline machines are unavailable and become selectable when they reconnect")
  func offlineTargets() {
    let (machines, _, provider) = makeController(localServer: nil)
    provider.cloudMachines = [makeCloudMachine(online: false)]
    #expect(PluginSettingsSession.availableMachines(in: machines).isEmpty)
    #expect(PluginSettingsSession(machines: machines, machineId: "cloud:dev-1", page: .browse) == nil)

    provider.cloudMachines = [makeCloudMachine()]
    machines.connection(for: "cloud:dev-1").status = MachineStatus(isReachable: false, label: "Offline")
    #expect(PluginSettingsSession.availableMachines(in: machines).isEmpty)

    machines.connection(for: "cloud:dev-1").status = MachineStatus(isReachable: true, label: "Connected")
    #expect(PluginSettingsSession.availableMachines(in: machines).map(\.id) == ["cloud:dev-1"])
  }

  @Test("Registry discovery and installation stay on the chosen machine when selection changes")
  func targetStaysFixed() async throws {
    let (machines, _, provider) = makeController(localServer: nil)
    provider.cloudMachines = [makeCloudMachine(), makeCloudMachine(deviceId: "dev-2", name: "Other Mac")]
    configurePlugins(provider)
    let session = try #require(PluginSettingsSession(machines: machines, machineId: "cloud:dev-1", page: .browse))
    let entry = try #require(try await session.fetchRegistry().entries.first)

    machines.selectMachine("cloud:dev-2")
    session.showInstall(source: entry.repo)
    let discovery = try await session.discover(source: entry.repo)
    try await session.install(source: entry.repo)

    #expect(session.page == .install(initialSource: "owner/repo"))
    #expect(session.machine.id == "cloud:dev-1")
    #expect(discovery.id == "owner.plugin")
    #expect(provider.configRequests == ["dev-1", "dev-1", "dev-1", "dev-1"])
    #expect(provider.requestTransport.paths.suffix(2) == ["/v1/plugins/discover-remote", "/v1/plugins/import-remote"])
  }

  @Test("Manual installation uses the explicitly chosen machine")
  func manualInstall() async throws {
    let (machines, _, provider) = makeController(localServer: nil)
    provider.cloudMachines = [makeCloudMachine(), makeCloudMachine(deviceId: "dev-2", name: "Other Mac")]
    configurePlugins(provider)
    let session = try #require(
      PluginSettingsSession(machines: machines, machineId: "cloud:dev-2", page: .install(initialSource: nil)))

    _ = try await session.discover(source: "owner/repo")
    try await session.install(source: "owner/repo")

    #expect(provider.configRequests == ["dev-2", "dev-2"])
  }

  @Test("Losing the target fails without installing on another machine; retry uses the recovered route")
  func missingTargetDoesNotFallBack() async throws {
    let (machines, _, provider) = makeController(localServer: nil)
    let target = makeCloudMachine()
    let other = makeCloudMachine(deviceId: "dev-2", name: "Other Mac")
    provider.cloudMachines = [target, other]
    configurePlugins(provider)
    let session = try #require(PluginSettingsSession(machines: machines, machineId: "cloud:dev-1", page: .browse))
    _ = try await session.discover(source: "owner/repo")

    provider.cloudMachines = [other]
    await #expect(throws: MachineUnreachableError.self) { try await session.install(source: "owner/repo") }
    #expect(provider.requestTransport.requestCount(for: "/v1/plugins/import-remote") == 0)

    provider.cloudMachines = [target, other]
    try await session.install(source: "owner/repo")
    #expect(provider.configRequests == ["dev-1", "dev-1"])
    #expect(provider.requestTransport.requestCount(for: "/v1/plugins/import-remote") == 1)
  }

  @Test("Configured machines can browse through their relay fallback")
  func configuredMachineRelay() async throws {
    let store = InMemoryStore()
    let remote = CodevisorMachine(
      id: "remote-studio", name: "Studio", baseURL: URL(string: "http://studio.invalid")!,
      kind: "remote", cloudDeviceId: "dev-1")
    try store.saveData(JSONEncoder().encode(MachineRegistry(remoteMachines: [remote])), forKey: "machines")
    let (machines, _, provider) = makeController(store: store, localServer: nil)
    provider.cloudMachines = [makeCloudMachine()]
    configurePlugins(provider)
    machines.connection(for: remote.id).status = MachineStatus(isReachable: true, label: "Connected", route: .relay)
    machines.markReady(for: remote.id)
    let session = try #require(PluginSettingsSession(machines: machines, machineId: remote.id, page: .browse))

    let registry = try await session.fetchRegistry()

    #expect(registry.entries.count == 1)
    #expect(provider.configRequests == ["dev-1", "dev-1"])
  }

  @Test("An installed-list failure does not hide a successfully fetched registry")
  func installedMarkersAreSupplementary() async throws {
    let (machines, _, provider) = makeController(localServer: nil)
    provider.cloudMachines = [makeCloudMachine()]
    configurePlugins(provider)
    provider.requestTransport.responsesByPath.removeValue(forKey: "/v1/plugins")
    let session = try #require(PluginSettingsSession(machines: machines, machineId: "cloud:dev-1", page: .browse))

    #expect(try await session.fetchRegistry().entries.count == 1)
    #expect(session.installedIds.isEmpty)
  }

  private func configurePlugins(_ provider: FakeCloudProvider) {
    provider.requestTransport.responsesByPath = [
      "/v1/plugins/registry": """
      {"entries":[{"id":"owner.plugin","name":"Plugin","version":"1.0.0","panes":[],
      "repo":"owner/repo","stars":0,"pushedAt":"2026-01-01T00:00:00Z"}]}
      """,
      "/v1/plugins": "{\"plugins\":[\(pluginJSON)]}",
      "/v1/plugins/import-remote": pluginJSON,
      "/v1/plugins/discover-remote": """
      {"id":"owner.plugin","name":"Plugin","version":"1.0.0","panes":[],
      "runCommand":"node server.js","alreadyInstalled":false}
      """,
    ]
  }

  private var pluginJSON: String {
    """
    {"id":"owner.plugin","name":"Plugin","version":"1.0.0","panes":[],
    "source":"managed","path":"/plugins/owner.plugin","state":"running"}
    """
  }
}
