import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Sandbox providers and profiles in Settings")
struct SandboxSettingsModelTests {
  @Test("A provider is named by its vendor and label, or by the Mac it runs on")
  func providerTitles() async {
    let model = SandboxSettingsModel()
    let studio = SandboxMachine(name: "Dylan's Mac Studio", client: SettingsFakeServerClient(serverId: "studio"))

    await model.load(from: SettingsFakeServerClient(), machines: [studio])

    #expect(
      model.providers.map(model.title(of:)) == [
        "E2B · 851 Labs", "E2B", "Tart · Dylan's Mac Studio", "Tart · another Mac",
      ])
  }

  @Test("A new profile starts on its provider's vendor, and switching vendor starts its fields over")
  func choosingProviders() async throws {
    let model = SandboxSettingsModel()
    await model.load(from: SettingsFakeServerClient(), machines: [])
    var draft = SandboxProfileDraft(
      provider: try #require(model.provider("labs")), vendor: SettingsFakeServerClient.e2b)

    let e2bName = draft.name
    draft.fields.text["template"] = "custom"
    draft.choose(try #require(model.provider("personal")), vendor: SettingsFakeServerClient.e2b)
    let keptTemplate = draft.fields.text["template"]
    draft.choose(try #require(model.provider("studio")), vendor: SettingsFakeServerClient.tart)

    #expect(e2bName == "E2B sandbox")
    #expect(keptTemplate == "custom")
    #expect(draft.name == "Tart VM")
    #expect(draft.request?.vendor == "tart")
    #expect(draft.request?.providerId == "studio")
    #expect(draft.fields.text["template"] == nil)
    #expect(draft.canSave)
  }

  @Test("A new provider needs a vendor and that vendor's credentials before it can be added")
  func providerDraft() {
    var draft = SandboxProviderDraft()
    let withoutVendor = draft.canSave

    draft.choose(SettingsFakeServerClient.e2b)
    let withoutKey = draft.canSave
    draft.fields.text["apiKey"] = "key"
    draft.label = " Work "

    #expect(!withoutVendor)
    #expect(!withoutKey)
    #expect(draft.canSave)
    #expect(
      draft.request == ServerSandboxProviderRequest(vendor: "e2b", label: "Work", values: ["apiKey": .string("key")]))
  }

  @Test("Setting up a vendor adds its provider, and the profile then saves on that provider")
  func firstProfile() async throws {
    let client = SettingsFakeServerClient(providers: [])
    let model = SandboxSettingsModel()
    await model.load(from: client, machines: [])
    var setUp = SandboxProviderDraft(vendor: SettingsFakeServerClient.e2b)
    setUp.fields.text["apiKey"] = "key"

    let provider = try #require(await model.save(setUp, using: client))
    let draft = SandboxProfileDraft(provider: provider, vendor: SettingsFakeServerClient.e2b)
    let saved = await model.save(draft, using: client)

    #expect(saved)
    #expect(client.calls == ["create provider e2b", "create profile E2B sandbox on new"])
    #expect(model.providers.map(\.id) == ["new"])
    #expect(model.profiles.map(\.name) == ["E2B sandbox"])
  }

  @Test("Editing a profile saves it on the same provider, and editing that provider updates it in place")
  func editingTheProvider() async throws {
    let client = SettingsFakeServerClient()
    let model = SandboxSettingsModel()
    await model.load(from: client, machines: [])
    let profile = ServerSandboxProfile(id: "p1", name: "Work", vendor: "e2b", providerId: "labs")
    let provider = try #require(model.provider("labs"))
    let editProvider = SandboxProviderDraft(vendor: SettingsFakeServerClient.e2b, provider: provider)

    let providerSaved = await model.save(editProvider, using: client)
    let profileSaved = await model.save(
      SandboxProfileDraft(profile: profile, vendor: SettingsFakeServerClient.e2b), using: client)

    #expect(editProvider.canSave)
    #expect(providerSaved?.id == "labs")
    #expect(profileSaved)
    #expect(client.calls == ["update provider labs", "update profile Work on labs"])
  }

  @Test("Settings pages push, go back, and after adding something jump to the next page or back to Sandboxes")
  func pageNavigation() {
    let start = ["sandboxes", "addProfile", "vendors"]
    let route: (SandboxSettingsPage) -> String = { "\($0)" }
    let isPage: (String) -> Bool = { $0 != "sandboxes" }

    let pushed = SandboxSettingsNavigation.push(.newProvider(vendorId: "tart")).applied(
      to: start, route: route, isSandboxPage: isPage)
    let next = SandboxSettingsNavigation.reset(to: .newProfile(providerId: "p")).applied(
      to: pushed, route: route, isSandboxPage: isPage)
    let done = SandboxSettingsNavigation.reset(to: nil).applied(to: next, route: route, isSandboxPage: isPage)
    let back = SandboxSettingsNavigation.pop.applied(to: start, route: route, isSandboxPage: isPage)

    #expect(pushed == start + ["newProvider(vendorId: \"tart\")"])
    #expect(next == ["sandboxes", "newProfile(providerId: \"p\")"])
    #expect(done == ["sandboxes"])
    #expect(back == ["sandboxes", "addProfile"])
  }

  @Test("Deleting a profile removes its provider once no other profile uses it")
  func deletingTheLastProfile() async {
    let client = SettingsFakeServerClient(
      profiles: [
        ServerSandboxProfile(id: "a", name: "A", vendor: "e2b", providerId: "labs"),
        ServerSandboxProfile(id: "b", name: "B", vendor: "e2b", providerId: "labs"),
        ServerSandboxProfile(id: "c", name: "C", vendor: "e2b", providerId: "personal"),
      ])
    let model = SandboxSettingsModel()
    await model.load(from: client, machines: [])

    for id in ["a", "c"] {
      guard let profile = model.profiles.first(where: { $0.id == id }) else { continue }
      await model.delete(profile, using: client)
    }

    #expect(client.calls == ["delete profile a", "delete profile c", "delete provider personal"])
    #expect(model.providers.map(\.id) == ["labs", "studio", "gone"])
  }
}

private final class SettingsFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  static let tart = ServerSandboxVendor(
    id: "tart", displayName: "Tart", sandboxNoun: "Tart VM", platform: "darwin", tested: true,
    providerFields: [.init(key: "machineId", label: "Mac", type: .machine, required: true, capability: "tart")],
    profileFields: [])
  static let e2b = ServerSandboxVendor(
    id: "e2b", displayName: "E2B", sandboxNoun: "E2B sandbox", platform: "linux", tested: true,
    providerFields: [.init(key: "apiKey", label: "API key", type: .secret, required: true)],
    profileFields: [.init(key: "template", label: "Template", type: .string)])

  static let existingProviders = [
    ServerSandboxProvider(id: "labs", vendor: "e2b", label: "851 Labs", secretsSet: ["apiKey"]),
    ServerSandboxProvider(id: "personal", vendor: "e2b", secretsSet: ["apiKey"]),
    ServerSandboxProvider(id: "studio", vendor: "tart", values: ["machineId": .string("studio")]),
    ServerSandboxProvider(id: "gone", vendor: "tart", values: ["machineId": .string("gone")]),
  ]

  let serverId: String
  let providers: [ServerSandboxProvider]
  let profiles: [ServerSandboxProfile]
  var calls: [String] = []

  init(
    serverId: String = "local", providers: [ServerSandboxProvider] = existingProviders,
    profiles: [ServerSandboxProfile] = []
  ) {
    self.serverId = serverId
    self.providers = providers
    self.profiles = profiles
  }

  func sandboxVendors() async throws -> ServerSandboxVendors {
    ServerSandboxVendors(vendors: [Self.tart, Self.e2b], capabilities: serverId == "local" ? [] : ["tart"])
  }

  func sandboxProviders() async throws -> [ServerSandboxProvider] { providers }

  func sandboxProfiles() async throws -> [ServerSandboxProfile] { profiles }

  func createSandboxProvider(_ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider {
    calls.append("create provider \(request.vendor)")
    return ServerSandboxProvider(id: "new", vendor: request.vendor, label: request.label, secretsSet: ["apiKey"])
  }

  func updateSandboxProvider(
    id: String, _ request: ServerSandboxProviderRequest
  ) async throws
    -> ServerSandboxProvider
  {
    calls.append("update provider \(id)")
    return ServerSandboxProvider(id: id, vendor: request.vendor, secretsSet: ["apiKey"])
  }

  func deleteSandboxProvider(id: String) async throws {
    calls.append("delete provider \(id)")
  }

  func createSandboxProfile(_ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile {
    calls.append("create profile \(request.name) on \(request.providerId ?? "nothing")")
    return ServerSandboxProfile(id: "p-new", name: request.name, vendor: request.vendor, providerId: request.providerId)
  }

  func updateSandboxProfile(id: String, _ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile {
    calls.append("update profile \(request.name) on \(request.providerId ?? "nothing")")
    return ServerSandboxProfile(id: id, name: request.name, vendor: request.vendor, providerId: request.providerId)
  }

  func deleteSandboxProfile(id: String) async throws {
    calls.append("delete profile \(id)")
  }

  func info() async throws -> ServerInfo {
    ServerInfo(id: serverId, name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
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
