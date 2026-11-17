import ACPKit
import CodevisorTestSupport
import ConcurrencyExtras
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("BotEditorModel model catalog")
struct BotEditorModelCatalogTests {
  private static let machine = CodevisorMachine.local.id

  @Test("New Bot opened after the machine's harnesses change replaces the stale model list")
  func invalidationReplacesStaleList() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let catalog = LockIsolated([Self.claude])
    fake.capabilitiesHandler = { _ in ServerCapabilities(harnesses: catalog.value) }
    let environment = makeEnvironment(fake)
    _ = await openedEditor(environment)
    catalog.setValue([Self.claude, Self.codex])

    let whileFresh = await openedEditor(environment).models?.harnesses.map(\.id)
    environment.harnessCatalogDidChange(onServer: Self.machine)
    let afterChange = await openedEditor(environment).models?.harnesses.map(\.id)

    #expect(whileFresh == ["claude-code"])
    #expect(afterChange == ["claude-code", "codex"])
  }

  @Test("Signing in to a harness while New Bot is open fills its empty picker")
  func signInFillsOpenPicker() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let signedIn = LockIsolated(false)
    fake.capabilitiesHandler = { _ in
      ServerCapabilities(harnesses: [signedIn.value ? Self.codex : Self.codexAwaitingSignIn])
    }
    let environment = makeEnvironment(fake)
    let editor = await openedEditor(environment)
    let keyBeforeSignIn = editor.modelCatalogKey
    #expect(editor.models?.harnesses.isEmpty == true)
    #expect(editor.models?.harnessId == nil)

    signedIn.setValue(true)
    _ = try await environment.refreshHarnessAuthentication(onServer: Self.machine)
    #expect(editor.modelCatalogKey != keyBeforeSignIn)
    await editor.loadModels()

    #expect(editor.models?.harnesses.map(\.id) == ["codex"])
    #expect(editor.models?.harnessId == "codex")
  }

  @Test("New Bot shows cached models while the machine answers, then re-picks when its harness is gone")
  func cachedModelsShowThenReseed() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let release = TestSignal()
    fake.capabilitiesHandler = { _ in
      await release.wait()
      return ServerCapabilities(harnesses: [Self.codex])
    }
    fake.resolvedCapabilitiesHandler = { _, harnessId, _ in
      ServerCapabilities(harnesses: [Self.claude, Self.codex].filter { $0.harness.id == harnessId })
    }
    let environment = makeEnvironment(fake)
    environment.configCache.store([Self.claude], forServer: Self.machine)
    let editor = BotEditorModel(target: .create, environment: environment)
    editor.serverId = Self.machine

    let load = Task { await editor.loadModels() }
    await awaitObserved { editor.models?.harnessId == "claude-code" }
    #expect(editor.models?.harnesses.map(\.id) == ["claude-code"])
    release.signal()
    await load.value

    #expect(editor.models?.harnesses.map(\.id) == ["codex"])
    #expect(editor.models?.harnessId == "codex")
    #expect(editor.models?.configSelections["model"] == "gpt-5")
  }

  private func openedEditor(_ environment: AppEnvironment) async -> BotEditorModel {
    let editor = BotEditorModel(target: .create, environment: environment)
    editor.serverId = Self.machine
    await editor.loadModels()
    return editor
  }

  private func makeEnvironment(_ fake: SyncFakeServerClient) -> AppEnvironment {
    AppEnvironment(
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineStore: InMemoryStore(),
      harnessService: PreviewHarnessService(),
      machineClientFactory: { _ in fake }
    )
  }

  nonisolated private static let claude = capability(id: "claude-code", name: "Claude Code", model: "opus")
  nonisolated private static let codex = capability(id: "codex", name: "Codex", model: "gpt-5")
  nonisolated private static let codexAwaitingSignIn = ServerHarnessCapability(
    harness: harness(id: "codex", name: "Codex", enabled: false), configOptions: [])

  nonisolated private static func capability(id: String, name: String, model: String) -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: harness(id: id, name: name, enabled: true),
      configOptions: [
        SessionConfigOption(
          id: "model", name: "Model", category: SessionConfigOption.Category.model, currentValue: model,
          options: [SessionConfigSelectOption(value: model, name: model)])
      ]
    )
  }

  nonisolated private static func harness(id: String, name: String, enabled: Bool) -> ServerHarness {
    ServerHarness(
      id: id, name: name, symbolName: "sparkle", source: "registry", launchKind: "executable",
      enabled: enabled, readiness: ServerHarnessReadiness(state: "ready", detail: nil))
  }
}
