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
        "E2B (851 Labs)", "E2B", "Tart on Dylan's Mac Studio", "Tart on another Mac",
      ])
  }

  @Test("Choosing a provider shows its vendor's fields, and switching vendor starts them over")
  func choosingProviders() async throws {
    let model = SandboxSettingsModel()
    await model.load(from: SettingsFakeServerClient(), machines: [])
    var draft = SandboxProfileDraft()
    let unchosen = draft.canSave

    draft.choose(try #require(model.provider("labs")), vendor: SettingsFakeServerClient.e2b)
    let e2bName = draft.name
    draft.fields.text["template"] = "custom"
    draft.choose(try #require(model.provider("personal")), vendor: SettingsFakeServerClient.e2b)
    let keptTemplate = draft.fields.text["template"]
    draft.choose(try #require(model.provider("studio")), vendor: SettingsFakeServerClient.tart)

    #expect(!unchosen)
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

  @Test("Saving a provider hands it back so the profile can select it")
  func savingProviders() async throws {
    let client = SettingsFakeServerClient()
    let model = SandboxSettingsModel()
    await model.load(from: client, machines: [])
    var draft = SandboxProviderDraft()
    draft.choose(SettingsFakeServerClient.e2b)
    draft.fields.text["apiKey"] = "key"

    let saved = try #require(await model.save(draft, using: client))

    #expect(saved.vendor == "e2b")
    #expect(model.provider(saved.id) == saved)
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

  let serverId: String

  init(serverId: String = "local") {
    self.serverId = serverId
  }

  func sandboxVendors() async throws -> ServerSandboxVendors {
    ServerSandboxVendors(vendors: [Self.tart, Self.e2b], capabilities: serverId == "local" ? [] : ["tart"])
  }

  func sandboxProviders() async throws -> [ServerSandboxProvider] {
    [
      ServerSandboxProvider(id: "labs", vendor: "e2b", label: "851 Labs", secretsSet: ["apiKey"]),
      ServerSandboxProvider(id: "personal", vendor: "e2b", secretsSet: ["apiKey"]),
      ServerSandboxProvider(id: "studio", vendor: "tart", values: ["machineId": .string("studio")]),
      ServerSandboxProvider(id: "gone", vendor: "tart", values: ["machineId": .string("gone")]),
    ]
  }

  func createSandboxProvider(_ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider {
    ServerSandboxProvider(id: "new", vendor: request.vendor, label: request.label, secretsSet: ["apiKey"])
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
