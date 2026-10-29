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

  @Test("Providers that would share a name are told apart by their labels, and others keep their plain name")
  func duplicateProviderTitles() async {
    let model = SandboxSettingsModel()
    let studio = SandboxMachine(name: "Mac Studio", client: SettingsFakeServerClient(serverId: "studio"))
    let onStudio: [String: SandboxFieldValue] = ["machineId": .string("studio")]
    let client = SettingsFakeServerClient(providers: [
      ServerSandboxProvider(id: "work", vendor: "tart", label: "Work", values: onStudio),
      ServerSandboxProvider(id: "plain", vendor: "tart", values: onStudio),
      ServerSandboxProvider(id: "labs", vendor: "e2b", label: "851 Labs", secretsSet: ["apiKey"]),
    ])

    await model.load(from: client, machines: [studio])

    #expect(
      model.providers.map(model.title(of:)) == [
        "Tart · Mac Studio (Work)", "Tart · Mac Studio", "E2B · 851 Labs",
      ])
  }

  @Test("Profiles show before a slow Mac answers, and its name fills in once it does")
  func slowMachine() async throws {
    let gate = FetchGate()
    let model = SandboxSettingsModel()
    let studio = SandboxMachine(
      name: "Mac Studio", client: SettingsFakeServerClient(serverId: "studio", infoGate: gate))
    let loading = Task { await model.load(from: SettingsFakeServerClient(), machines: [studio]) }

    await gate.awaitWaiter()
    let loadedWhileWaiting = model.hasLoaded
    let titleWhileWaiting = model.provider("studio").map(model.title(of:))
    await gate.release()
    await loading.value

    #expect(loadedWhileWaiting)
    #expect(titleWhileWaiting == "Tart · another Mac")
    #expect(model.provider("studio").map(model.title(of:)) == "Tart · Mac Studio")
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

    let added = await model.save(setUp, using: client)
    guard case let .saved(provider) = added else {
      Issue.record("Expected the provider to save, got \(added)")
      return
    }
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
    #expect(providerSaved == .saved(ServerSandboxProvider(id: "labs", vendor: "e2b", secretsSet: ["apiKey"])))
    #expect(profileSaved)
    #expect(client.calls == ["update provider labs", "update profile Work on labs"])
  }

  @Test("A provider needs only its token until the server offers a choice, which then starts on its default")
  func offeredChoice() async {
    let client = SettingsFakeServerClient(providers: [])
    let model = SandboxSettingsModel()
    var draft = SandboxProviderDraft(vendor: SettingsFakeServerClient.vercel)
    draft.fields.text["token"] = "tok"
    let fieldsBefore = draft.shownFields.map(\.key)
    let couldSave = draft.canSave

    let first = await model.save(draft, using: client)
    let message = model.errorMessage
    if case let .choose(field) = first { draft.offer(field) }
    let fieldsAfter = draft.shownFields.map(\.key)
    let chosen = draft.request?.values["teamId"]
    let second = await model.save(draft, using: client)

    #expect(fieldsBefore == ["token"])
    #expect(couldSave)
    #expect(first == .choose(SettingsFakeServerClient.teamChoice))
    #expect(message == "Choose the team for your sandboxes.")
    #expect(fieldsAfter == ["token", "teamId"])
    #expect(chosen == .string("team_labs"))
    #expect(second == .saved(ServerSandboxProvider(id: "new", vendor: "vercel", secretsSet: ["apiKey"])))
    #expect(model.errorMessage == nil)
    #expect(client.calls == ["create provider vercel", "create provider vercel"])
  }

  @Test("A profile page pushes onto Settings, and going back or deleting it returns to Sandboxes")
  func pageNavigation() {
    let start = ["sandboxes"]
    let route: (SandboxSettingsPage) -> String = { "\($0)" }
    let isPage: (String) -> Bool = { $0 != "sandboxes" }

    let pushed = SandboxSettingsNavigation.push(.editProfile(profileId: "p")).applied(
      to: start, route: route, isSandboxPage: isPage)
    let back = SandboxSettingsNavigation.pop.applied(to: pushed, route: route, isSandboxPage: isPage)
    let reset = SandboxSettingsNavigation.reset(to: nil).applied(to: pushed, route: route, isSandboxPage: isPage)

    #expect(pushed == ["sandboxes", "editProfile(profileId: \"p\")"])
    #expect(back == start)
    #expect(reset == start)
  }

  @Test("Switching a new profile to another vendor's provider keeps what was typed and takes the new defaults")
  func switchingVendorKeepsTypedFields() {
    let first = ServerSandboxVendor(
      id: "first", displayName: "First", sandboxNoun: "first box", platform: "linux", tested: true,
      providerFields: [],
      profileFields: [
        .init(key: "template", label: "Template", type: .string),
        .init(key: "cpu", label: "CPUs", type: .number, defaultValue: .number(2)),
        .init(key: "region", label: "Region", type: .choice, choices: [.init(value: "mars", label: "Mars")]),
      ])
    let second = ServerSandboxVendor(
      id: "second", displayName: "Second", sandboxNoun: "second box", platform: "linux", tested: true,
      providerFields: [],
      profileFields: [
        .init(key: "template", label: "Template", type: .string),
        .init(key: "cpu", label: "CPUs", type: .number, defaultValue: .number(4)),
        .init(
          key: "region", label: "Region", type: .choice, defaultValue: .string("us"),
          choices: [.init(value: "us", label: "US")]),
      ])
    var draft = SandboxProfileDraft(provider: ServerSandboxProvider(id: "a", vendor: "first"), vendor: first)
    draft.name = "Work"
    draft.fields.text["template"] = "custom"
    draft.fields.text["region"] = "mars"

    draft.choose(ServerSandboxProvider(id: "b", vendor: "second"), vendor: second)

    #expect(draft.name == "Work")
    #expect(draft.request?.providerId == "b")
    #expect(draft.fields.text["template"] == "custom")
    #expect(draft.fields.text["cpu"] == "4")
    #expect(draft.fields.text["region"] == "us")
  }

  @Test("Memory offers the steps up to the provider Mac's limit, falls back without it, and fits a saved size")
  func memorySteps() async throws {
    let tart = SettingsFakeServerClient.tart
    let bigOnStudio = Self.tartProfile(id: "a", on: "studio", memoryGiB: 24)
    let bigOnUnknownMac = Self.tartProfile(id: "b", on: "gone", memoryGiB: 24)
    let model = SandboxSettingsModel()
    let studio = SandboxMachine(name: "Mac Studio", client: SettingsFakeServerClient(serverId: "studio"))
    await model.load(from: SettingsFakeServerClient(profiles: [bigOnStudio, bigOnUnknownMac]), machines: [studio])
    let memory = try #require(tart.profileFields.first)
    let studioProvider = try #require(model.provider("studio"))
    let unknownMacProvider = try #require(model.provider("gone"))

    let newOnStudio = try #require(
      model.steps(for: memory, in: SandboxProfileDraft(provider: studioProvider, vendor: tart)))
    let newOnUnknownMac = model.steps(
      for: memory, in: SandboxProfileDraft(provider: unknownMacProvider, vendor: tart))
    let savedOnStudio = model.steps(for: memory, in: SandboxProfileDraft(profile: bigOnStudio, vendor: tart))
    let savedOnUnknownMac = model.steps(for: memory, in: SandboxProfileDraft(profile: bigOnUnknownMac, vendor: tart))

    #expect(newOnStudio.values == [4, 6, 8, 12, 16, 20])
    #expect(newOnUnknownMac?.values == [4, 6, 8])
    #expect(savedOnStudio?.fitted(24) == 20)
    #expect(savedOnUnknownMac?.values == [4, 6, 8, 12, 16, 24])
    #expect(newOnStudio.fitted(10) == 8)
    #expect(newOnStudio.fitted(2) == 4)
    #expect(newOnStudio.fitted(nil) == 4)
  }

  private static func tartProfile(id: String, on providerId: String, memoryGiB: Double) -> ServerSandboxProfile {
    ServerSandboxProfile(
      id: id, name: id, vendor: "tart", providerId: providerId, values: ["memoryGiB": .number(memoryGiB)])
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

  @Test(
    "Deleting a provider counts its profiles and live workspaces once across every reachable Mac, then deletes it on each"
  )
  func deletingAProvider() async throws {
    let local = SettingsFakeServerClient(
      profiles: [
        ServerSandboxProfile(id: "a", name: "A", vendor: "e2b", providerId: "labs"),
        ServerSandboxProfile(id: "b", name: "B", vendor: "e2b", providerId: "labs"),
        ServerSandboxProfile(id: "c", name: "C", vendor: "e2b", providerId: "personal"),
      ],
      sandboxes: [
        Self.sandbox("live", on: "labs", workspaceId: "w1"),
        Self.sandbox("archived", on: "labs", workspaceId: "w2", state: "archived"),
        Self.sandbox("failed", on: "labs", workspaceId: "w3", state: "failed"),
        Self.sandbox("prewarmed", on: "labs"),
        Self.sandbox("other", on: "personal", workspaceId: "w4"),
      ])
    let studio = SettingsFakeServerClient(
      serverId: "studio",
      sandboxes: [
        Self.sandbox("live", on: "labs", workspaceId: "w1"),
        Self.sandbox("studio-live", on: "labs", workspaceId: "w5"),
      ])
    let model = SandboxSettingsModel()
    await model.load(from: local, machines: [])
    let machines = [SandboxMachine(name: "Local", client: local), SandboxMachine(name: "Studio", client: studio)]
    let labs = try #require(model.provider("labs"))

    let removal = await model.removal(of: labs, on: machines, offline: ["MacBook Air"])
    let deleted = await model.delete(labs, on: machines)

    #expect(
      removal
        == SandboxProviderRemoval(
          providerTitle: "E2B · 851 Labs", profileCount: 2, workspaceCount: 2, offlineMachineNames: ["MacBook Air"]))
    #expect(deleted)
    #expect(local.calls == ["delete provider labs with its profiles"])
    #expect(studio.calls == ["delete provider labs with its profiles"])
    #expect(model.profiles.map(\.id) == ["c"])
    #expect(model.providers.map(\.id) == ["personal", "studio", "gone"])
  }

  @Test("A provider stays when any reachable Mac fails to delete it, and the error shows")
  func failedProviderDeletion() async throws {
    let broken = SettingsFakeServerClient(serverId: "studio", deleteFailure: 500)
    let model = SandboxSettingsModel()
    await model.load(from: SettingsFakeServerClient(), machines: [])
    let labs = try #require(model.provider("labs"))

    let deleted = await model.delete(labs, on: [SandboxMachine(name: "Studio", client: broken)])

    #expect(!deleted)
    #expect(model.provider("labs") != nil)
    #expect(model.errorMessage != nil)
  }

  @Test("Deleting a provider skips machines that can't run sandboxes at all")
  func providerDeletionSkipsMachinesWithoutSandboxes() async throws {
    let linux = SettingsFakeServerClient(serverId: "linux", deleteFailure: 501)
    let local = SettingsFakeServerClient()
    let model = SandboxSettingsModel()
    await model.load(from: local, machines: [])
    let labs = try #require(model.provider("labs"))

    let deleted = await model.delete(
      labs, on: [SandboxMachine(name: "Linux", client: linux), SandboxMachine(name: "Local", client: local)])

    #expect(deleted)
    #expect(local.calls == ["delete provider labs with its profiles"])
    #expect(model.provider("labs") == nil)
  }

  @Test("The delete confirmation names the counts, says unpushed work is lost, and names offline Macs")
  func removalMessage() {
    let full = SandboxProviderRemoval(
      providerTitle: "E2B", profileCount: 2, workspaceCount: 3, offlineMachineNames: ["Studio", "Air"])
    let single = SandboxProviderRemoval(
      providerTitle: "E2B", profileCount: 1, workspaceCount: 1, offlineMachineNames: [])
    let quiet = SandboxProviderRemoval(
      providerTitle: "E2B", profileCount: 1, workspaceCount: 0, offlineMachineNames: ["Studio"])

    #expect(full.title == "Delete “E2B”?")
    #expect(
      full.message
        == "This also deletes its 2 profiles and archives the 3 workspaces using them. "
        + "Archiving destroys their sandboxes, so any work that isn’t pushed is lost. "
        + "Studio and Air are offline. Sandboxes they started keep running, and cost money, until they’re back online.")
    #expect(
      single.message
        == "This also deletes its 1 profile and archives the 1 workspace using it. "
        + "Archiving destroys its sandbox, so any work that isn’t pushed is lost.")
    #expect(
      quiet.message
        == "This also deletes its 1 profile. "
        + "Studio is offline. Sandboxes it started keep running, and cost money, until it’s back online.")
  }

  private static func sandbox(
    _ id: String, on providerId: String, workspaceId: String? = nil, state: String = "ready"
  ) -> ServerSandbox {
    ServerSandbox(id: id, vendor: "e2b", name: id, state: state, accountId: providerId, workspaceId: workspaceId)
  }
}

private final class SettingsFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  static let tart = ServerSandboxVendor(
    id: "tart", displayName: "Tart", sandboxNoun: "Tart VM", platform: "darwin", tested: true,
    providerFields: [.init(key: "machineId", label: "Mac", type: .machine, required: true, capability: "tart")],
    profileFields: [
      .init(
        key: "memoryGiB", label: "Memory", type: .number, defaultValue: .number(4), min: 4, max: 512,
        steps: [4, 6, 8, 12, 16, 24, 32], fallbackMax: 8, unit: "GB")
    ])
  static let e2b = ServerSandboxVendor(
    id: "e2b", displayName: "E2B", sandboxNoun: "E2B sandbox", platform: "linux", tested: true,
    providerFields: [.init(key: "apiKey", label: "API key", type: .secret, required: true)],
    profileFields: [.init(key: "template", label: "Template", type: .string)])

  static let vercel = ServerSandboxVendor(
    id: "vercel", displayName: "Vercel Sandbox", sandboxNoun: "Vercel sandbox", platform: "linux", tested: true,
    providerFields: [
      .init(key: "token", label: "Access token", type: .secret, required: true),
      .init(key: "teamId", label: "Team", type: .choice),
    ],
    profileFields: [])
  static let teamChoice = ServerSandboxField(
    key: "teamId", label: "Team", type: .choice, required: true, defaultValue: .string("team_labs"),
    choices: [.init(value: "team_me", label: "Mine"), .init(value: "team_labs", label: "851 Labs")])
  static let teamChoiceReply = """
    {"error":"Choose the team for your sandboxes.","code":"sandboxChoiceNeeded","details":{"field":\
    {"key":"teamId","label":"Team","type":"choice","required":true,"default":"team_labs",\
    "choices":[{"value":"team_me","label":"Mine"},{"value":"team_labs","label":"851 Labs"}]}}}
    """

  static let existingProviders = [
    ServerSandboxProvider(id: "labs", vendor: "e2b", label: "851 Labs", secretsSet: ["apiKey"]),
    ServerSandboxProvider(id: "personal", vendor: "e2b", secretsSet: ["apiKey"]),
    ServerSandboxProvider(id: "studio", vendor: "tart", values: ["machineId": .string("studio")]),
    ServerSandboxProvider(id: "gone", vendor: "tart", values: ["machineId": .string("gone")]),
  ]

  let serverId: String
  let providers: [ServerSandboxProvider]
  let profiles: [ServerSandboxProfile]
  let infoGate: FetchGate?
  let listedSandboxes: [ServerSandbox]
  let deleteFailure: Int?
  var calls: [String] = []

  init(
    serverId: String = "local", providers: [ServerSandboxProvider] = existingProviders,
    profiles: [ServerSandboxProfile] = [], sandboxes: [ServerSandbox] = [], infoGate: FetchGate? = nil,
    deleteFailure: Int? = nil
  ) {
    self.serverId = serverId
    self.providers = providers
    self.profiles = profiles
    self.listedSandboxes = sandboxes
    self.infoGate = infoGate
    self.deleteFailure = deleteFailure
  }

  func sandboxes() async throws -> [ServerSandbox] { listedSandboxes }

  func deleteSandboxProviderAndProfiles(id: String) async throws {
    if let deleteFailure { throw CodevisorServerClientError.httpStatus(deleteFailure, #"{"error":"No"}"#) }
    calls.append("delete provider \(id) with its profiles")
  }

  func sandboxVendors() async throws -> ServerSandboxVendors {
    guard serverId != "local" else { return ServerSandboxVendors(vendors: [Self.tart, Self.e2b]) }
    return ServerSandboxVendors(
      vendors: [Self.tart, Self.e2b], capabilities: ["tart"], maximums: ["tart": ["memoryGiB": 20]])
  }

  func sandboxProviders() async throws -> [ServerSandboxProvider] { providers }

  func sandboxProfiles() async throws -> [ServerSandboxProfile] { profiles }

  func createSandboxProvider(_ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider {
    calls.append("create provider \(request.vendor)")
    if request.vendor == "vercel", request.values["teamId"] == nil {
      throw CodevisorServerClientError.httpStatus(409, Self.teamChoiceReply)
    }
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
    await infoGate?.wait()
    return ServerInfo(
      id: serverId, name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
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
