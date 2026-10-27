import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Sandbox profiles in the machine picker")
struct SandboxProfileCatalogTests {
  @Test("Each profile asks the server that would start it whether it can, right now")
  func reasonsComeFromTheHost() async {
    let composer = CatalogFakeServerClient(
      profiles: [.init(id: "ubuntu", name: "Ubuntu Sandbox", provider: "e2b", accountId: "a")] + tartProfiles,
      availability: [
        .init(profileId: "ubuntu"),
        .init(profileId: "studio", disabledReason: "Runs on another Mac"),
      ])
    let studio = CatalogFakeServerClient(
      availability: [.init(profileId: "studio", disabledReason: "The limit of 2 macOS VMs per Mac has been reached")])
    let catalog = SandboxProfileCatalog()

    await catalog.load(from: composer) { $0 == "server-studio" ? studio : nil }

    #expect(catalog.choices.map(\.target.pickerTitle) == ["New Ubuntu Sandbox", "New Studio VM", "New Laptop VM"])
    #expect(
      catalog.choices.map(\.disabledReason) == [
        nil, "The limit of 2 macOS VMs per Mac has been reached", "Its Mac isn't connected",
      ])
    #expect(catalog.choices.map(\.target.machineNoun) == ["E2B sandbox", "Tart VM", "Tart VM"])
  }

  @Test("A server that can't answer leaves no profiles to pick")
  func unreachableComposer() async {
    let catalog = SandboxProfileCatalog()

    await catalog.load(from: CatalogFakeServerClient(failing: true)) { _ in nil }

    #expect(catalog.choices.isEmpty)
  }

  private var tartProfiles: [ServerSandboxProfile] {
    [
      .init(id: "studio", name: "Studio VM", provider: "tart", values: ["machineId": .string("server-studio")]),
      .init(id: "laptop", name: "Laptop VM", provider: "tart", values: ["machineId": .string("server-laptop")]),
    ]
  }
}

private final class CatalogFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  let profiles: [ServerSandboxProfile]
  let availability: [ServerSandboxAvailability]
  let failing: Bool

  init(profiles: [ServerSandboxProfile] = [], availability: [ServerSandboxAvailability] = [], failing: Bool = false) {
    self.profiles = profiles
    self.availability = availability
    self.failing = failing
  }

  func sandboxProviders() async throws -> ServerSandboxProviders {
    if failing { throw CodevisorServerClientError.invalidResponse }
    return ServerSandboxProviders(providers: [
      .init(
        id: "tart", displayName: "Tart", sandboxNoun: "Tart VM", platform: "darwin", tested: true,
        accountFields: [], profileFields: [.init(key: "machineId", label: "Mac", type: .machine)]),
      .init(
        id: "e2b", displayName: "E2B", sandboxNoun: "E2B sandbox", platform: "linux", tested: true,
        accountFields: [.init(key: "apiKey", label: "API key", type: .secret)], profileFields: []),
    ])
  }

  func sandboxProfiles() async throws -> [ServerSandboxProfile] {
    if failing { throw CodevisorServerClientError.invalidResponse }
    return profiles
  }

  func sandboxAvailability() async throws -> [ServerSandboxAvailability] { availability }

  func info() async throws -> ServerInfo {
    ServerInfo(id: "local", name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
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
