import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("A chat handing off to its started sandbox")
struct SandboxHandoffTests {
  @Test("The composer keeps showing the chosen model while the chat moves to the sandbox")
  func composerKeepsItsModelAcrossTheHandoff() {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/hello-world"), serverId: "local"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: SyncFakeServerClient(projects: [], sessions: [])
    )
    controller.harnesses = [
      ServerHarness(
        id: "codex", name: "Codex", symbolName: "sparkle", source: "registry",
        launchKind: "executable", enabled: true, readiness: ServerHarnessReadiness(state: "ready"))
    ]
    controller.selectedHarnessId = "codex"
    controller.configOptionsByHarness["codex"] = [
      SessionConfigOption(
        id: "model", name: "Model", category: SessionConfigOption.Category.model, currentValue: "gpt-5.6-sol",
        options: [
          SessionConfigSelectOption(value: "gpt-5.6-sol", name: "GPT-5.6 Sol"),
          SessionConfigSelectOption(value: "gpt-5.6-mini", name: "GPT-5.6 Mini"),
        ])
    ]
    controller.hasSentFirst = true
    controller.firstSendSelections = ["model": "gpt-5.6-mini"]
    let sandbox = Project.fromFolder(URL(fileURLWithPath: "/home/codevisor/hello-world"), serverId: "sandbox")

    controller.handOff(to: sandbox, serverClient: SyncFakeServerClient(projects: [], sessions: []))

    #expect(controller.project.serverId == "sandbox")
    #expect(controller.modelPickerPresentation.modelChip == .model(name: "GPT-5.6 Mini"))
    #expect(!controller.isLoadingModelMenu)
  }
}
