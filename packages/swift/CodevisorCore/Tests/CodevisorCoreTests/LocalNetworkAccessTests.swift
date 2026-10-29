import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Local Network access")
struct LocalNetworkAccessTests {
  @Test("A new install stays relay-only, and the local server follows each choice in order")
  func newInstallFollowsChoices() async {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    let environment = makeEnvironment(client: client, preferences: ClientPreferences())
    #expect(environment.localNetworkAccess == .unasked)
    #expect(environment.needsLocalNetworkChoice)
    #expect(!environment.cloud.directPaths.allowsDirectPaths)

    environment.noteMachineConnected(CodevisorMachine.local.id)
    await client.directPathRequested.wait(for: 1)
    environment.setLocalNetworkAccess(.requested)
    environment.setLocalNetworkAccess(.deferred)
    environment.setLocalNetworkAccess(.requested)
    await client.directPathRequested.wait(for: 4)

    #expect(client.directPathRequests == [false, true, false, true])
    #expect(environment.cloud.directPaths.allowsDirectPaths)
    #expect(environment.hasRequestedLocalNetworkAccess)
  }

  @Test("An install that already connects over LAN keeps it on")
  func existingChoiceSurvives() async {
    let preferences = ClientPreferences()
    preferences.set(LocalNetworkAccess.requested, forKey: LocalNetworkAccess.preferenceKey)
    let client = SyncFakeServerClient(projects: [], sessions: [])
    let environment = makeEnvironment(client: client, preferences: preferences)
    #expect(environment.cloud.directPaths.allowsDirectPaths)

    environment.noteMachineConnected(CodevisorMachine.local.id)
    await client.directPathRequested.wait(for: 1)
    #expect(client.directPathRequests == [true])
  }

  private func makeEnvironment(client: SyncFakeServerClient, preferences: ClientPreferences) -> AppEnvironment {
    AppEnvironment(
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineStore: InMemoryStore(),
      localServer: StubLocalServer(),
      machineClientFactory: { _ in client },
      preferences: preferences
    )
  }
}
