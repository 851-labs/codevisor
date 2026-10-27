import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Adding a sandbox profile")
struct SandboxSettingsModelTests {
  @Test("Someone with no accounts picks from every provider; otherwise from their accounts and keyless providers")
  func choices() async {
    let model = SandboxSettingsModel()
    let fresh = SandboxSettingsModel()

    await model.load(from: SettingsFakeServerClient(accounts: [labs]), machines: [])
    await fresh.load(from: SettingsFakeServerClient(), machines: [])

    #expect(model.setUpChoices.map(model.title(of:)) == ["E2B (851 Labs)", "Tart"])
    #expect(model.signInChoices.map(model.title(of:)) == ["E2B"])
    #expect(fresh.setUpChoices.map(fresh.title(of:)) == ["Tart"])
    #expect(fresh.providerChoices.map(fresh.title(of:)) == ["Tart", "E2B"])
    #expect(model.setUpChoices.map(\.signsIn) == [false, false])
    #expect(model.signInChoices.map(\.signsIn) == [true])
    #expect(model.choice(id: "labs")?.account == labs)
    #expect(model.choice(id: "e2b")?.signsIn == true)
  }

  @Test("A new provider signs in first, and a failed profile keeps that account instead of signing in again")
  func signsInOnce() async throws {
    let client = SettingsFakeServerClient(failsNextProfile: true)
    let model = SandboxSettingsModel()
    await model.load(from: client, machines: [])
    var draft = SandboxNewProfileDraft(choice: try #require(model.signInChoices.first))
    draft.account?.fields.text["apiKey"] = "key"
    draft.profile.name = "Ubuntu"

    guard case let .failed(remaining) = await model.create(draft, using: client) else {
      Issue.record("The profile should have failed")
      return
    }
    let retried = await model.create(remaining, using: client)

    #expect(retried == .created)
    #expect(remaining.account == nil)
    #expect(client.createdAccounts == 1)
    #expect(client.profileRequests.map(\.accountId) == ["account-1", "account-1"])
    #expect(model.profiles.map(\.name) == ["Ubuntu"])
  }

  @Test("A profile needs its credentials and name filled in before it can be added")
  func canSave() throws {
    let e2b = SandboxSetupChoice(provider: SettingsFakeServerClient.e2b)
    var draft = SandboxNewProfileDraft(choice: e2b)
    let keyless = SandboxNewProfileDraft(choice: SandboxSetupChoice(provider: SettingsFakeServerClient.tart))

    let withoutKey = draft.canSave
    draft.account?.fields.text["apiKey"] = "key"

    #expect(!withoutKey)
    #expect(draft.canSave)
    #expect(keyless.account == nil)
    #expect(keyless.canSave)
  }

  private var labs: ServerSandboxAccount {
    ServerSandboxAccount(id: "labs", provider: "e2b", label: "851 Labs", secretsSet: ["apiKey"])
  }
}

private final class SettingsFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  static let tart = ServerSandboxProviderInfo(
    id: "tart", displayName: "Tart", sandboxNoun: "Tart VM", platform: "darwin", tested: true,
    accountFields: [], profileFields: [])
  static let e2b = ServerSandboxProviderInfo(
    id: "e2b", displayName: "E2B", sandboxNoun: "E2B sandbox", platform: "linux", tested: true,
    accountFields: [.init(key: "apiKey", label: "API key", type: .secret, required: true)], profileFields: [])

  let accounts: [ServerSandboxAccount]
  var failsNextProfile: Bool
  var createdAccounts = 0
  var profileRequests: [ServerSandboxProfileRequest] = []

  init(accounts: [ServerSandboxAccount] = [], failsNextProfile: Bool = false) {
    self.accounts = accounts
    self.failsNextProfile = failsNextProfile
  }

  func sandboxProviders() async throws -> ServerSandboxProviders {
    ServerSandboxProviders(providers: [Self.tart, Self.e2b])
  }

  func sandboxAccounts() async throws -> [ServerSandboxAccount] { accounts }

  func createSandboxAccount(_ request: ServerSandboxAccountRequest) async throws -> ServerSandboxAccount {
    createdAccounts += 1
    return ServerSandboxAccount(id: "account-\(createdAccounts)", provider: request.provider)
  }

  func createSandboxProfile(_ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile {
    profileRequests.append(request)
    if failsNextProfile {
      failsNextProfile = false
      throw CodevisorServerClientError.invalidResponse
    }
    return ServerSandboxProfile(
      id: "profile", name: request.name, provider: request.provider, accountId: request.accountId)
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
