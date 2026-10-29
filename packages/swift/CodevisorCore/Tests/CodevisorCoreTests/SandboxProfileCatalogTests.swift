import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Sandbox profiles in the machine picker")
struct SandboxProfileCatalogTests {
  @Test("Each profile asks the server that would start it whether it can, right now")
  func reasonsComeFromTheHost() async {
    let composer = CatalogFakeServerClient(
      profiles: [ubuntuProfile] + tartProfiles,
      availability: [
        .init(profileId: "ubuntu"),
        .init(profileId: "studio", disabledReason: "Runs on another Mac"),
      ])
    let studio = CatalogFakeServerClient(
      availability: [.init(profileId: "studio", disabledReason: "This Mac already runs 2 macOS VMs", full: true)])
    let catalog = SandboxProfileCatalog()

    await catalog.load(composerId: "composer", from: composer) { $0 == "server-studio" ? .ready(studio) : .unreachable }

    let choices = catalog.choices(for: "composer")
    #expect(choices.map(\.target.profileName) == ["Ubuntu Sandbox", "Studio VM", "Laptop VM"])
    #expect(
      choices.map(\.availability) == [
        .available, .full("This Mac already runs 2 macOS VMs"), .unavailable("Its Mac isn't connected"),
      ])
    #expect(choices.map(\.target.machineNoun) == ["E2B sandbox", "Tart VM", "Tart VM"])
  }

  @Test("A server that can't answer leaves no profiles to pick")
  func unreachableComposer() async {
    let catalog = SandboxProfileCatalog()

    await catalog.load(composerId: "composer", from: CatalogFakeServerClient(failing: true)) { _ in .unreachable }

    #expect(catalog.choices(for: "composer").isEmpty)
  }

  @Test("A refresh that can't reach the server keeps the profiles already shown")
  func failedRefreshKeepsProfiles() async {
    let catalog = SandboxProfileCatalog()
    let composer = CatalogFakeServerClient(
      profiles: [ubuntuProfile], availability: [.init(profileId: "ubuntu", disabledReason: "Add an E2B account")])
    await catalog.load(composerId: "composer", from: composer) { _ in .unreachable }

    await catalog.load(composerId: "composer", from: CatalogFakeServerClient(failing: true)) { _ in .unreachable }

    #expect(catalog.choices(for: "composer") == [ubuntuChoice(.unavailable("Add an E2B account"))])
  }

  @Test("Profiles show as being checked until their server answers")
  func profilesShowWhileChecking() async {
    let gate = TestSignal()
    let composer = CatalogFakeServerClient(
      profiles: [ubuntuProfile], availability: [.init(profileId: "ubuntu")], availabilityGate: gate)
    let catalog = SandboxProfileCatalog()

    let load = Task { await catalog.load(composerId: "composer", from: composer) { _ in .unreachable } }
    await composer.availabilityRequested.wait()

    #expect(catalog.choices(for: "composer") == [ubuntuChoice(.checking)])
    gate.signal()
    await load.value
    #expect(catalog.choices(for: "composer") == [ubuntuChoice(.available)])
    #expect(catalog.choices(for: "other-composer") == [ubuntuChoice(.checking)])
  }

  @Test("An availability check that fails keeps the last answer")
  func failedCheckKeepsReason() async {
    let catalog = SandboxProfileCatalog()
    let composer = CatalogFakeServerClient(
      profiles: [ubuntuProfile], availability: [.init(profileId: "ubuntu", disabledReason: "Add an E2B account")])
    await catalog.load(composerId: "composer", from: composer) { _ in .unreachable }

    let unanswered = CatalogFakeServerClient(profiles: [ubuntuProfile], failingAvailability: true)
    await catalog.load(composerId: "composer", from: unanswered) { _ in .unreachable }
    await catalog.load(composerId: "other-composer", from: unanswered) { _ in .unreachable }

    #expect(catalog.choices(for: "composer") == [ubuntuChoice(.unavailable("Add an E2B account"))])
    #expect(catalog.choices(for: "other-composer") == [ubuntuChoice(.available)])
  }

  @Test("A profile on this Mac stays in Checking while its server is still starting")
  func startingHostIsChecking() async {
    let composer = CatalogFakeServerClient(profiles: tartProfiles)
    let catalog = SandboxProfileCatalog()

    await catalog.load(composerId: "composer", from: composer) { $0 == "server-studio" ? .starting : .unreachable }

    #expect(
      catalog.choices(for: "composer").map(\.availability) == [.checking, .unavailable("Its Mac isn't connected")])
  }

  private var ubuntuProfile: ServerSandboxProfile {
    .init(id: "ubuntu", name: "Ubuntu Sandbox", vendor: "e2b", providerId: "a")
  }

  private func ubuntuChoice(_ availability: SandboxProfileAvailability) -> SandboxProfileChoice {
    SandboxProfileChoice(
      target: SandboxTarget(
        profileId: "ubuntu", profileName: "Ubuntu Sandbox", vendorId: "e2b", machineNoun: "E2B sandbox"),
      availability: availability)
  }

  private var tartProfiles: [ServerSandboxProfile] {
    [
      .init(id: "studio", name: "Studio VM", vendor: "tart", providerId: "tart-studio"),
      .init(id: "laptop", name: "Laptop VM", vendor: "tart", providerId: "tart-laptop"),
    ]
  }
}

private final class CatalogFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  let profiles: [ServerSandboxProfile]
  let availability: [ServerSandboxAvailability]
  let failing: Bool
  let failingAvailability: Bool
  let availabilityGate: TestSignal?
  let availabilityRequested = TestSignal()

  init(
    profiles: [ServerSandboxProfile] = [],
    availability: [ServerSandboxAvailability] = [],
    failing: Bool = false,
    failingAvailability: Bool = false,
    availabilityGate: TestSignal? = nil
  ) {
    self.profiles = profiles
    self.availability = availability
    self.failing = failing
    self.failingAvailability = failingAvailability
    self.availabilityGate = availabilityGate
  }

  func sandboxProviders() async throws -> [ServerSandboxProvider] {
    if failing { throw CodevisorServerClientError.invalidResponse }
    return ["studio", "laptop"].map { mac in
      ServerSandboxProvider(id: "tart-\(mac)", vendor: "tart", values: ["machineId": .string("server-\(mac)")])
    }
  }

  func sandboxVendors() async throws -> ServerSandboxVendors {
    if failing { throw CodevisorServerClientError.invalidResponse }
    return ServerSandboxVendors(vendors: [
      .init(
        id: "tart", displayName: "Tart", sandboxNoun: "Tart VM", platform: "darwin", tested: true,
        providerFields: [.init(key: "machineId", label: "Mac", type: .machine)], profileFields: []),
      .init(
        id: "e2b", displayName: "E2B", sandboxNoun: "E2B sandbox", platform: "linux", tested: true,
        providerFields: [.init(key: "apiKey", label: "API key", type: .secret)], profileFields: []),
    ])
  }

  func sandboxProfiles() async throws -> [ServerSandboxProfile] {
    if failing { throw CodevisorServerClientError.invalidResponse }
    return profiles
  }

  func sandboxAvailability() async throws -> [ServerSandboxAvailability] {
    availabilityRequested.signal()
    await availabilityGate?.wait()
    if failing || failingAvailability { throw CodevisorServerClientError.invalidResponse }
    return availability
  }

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
