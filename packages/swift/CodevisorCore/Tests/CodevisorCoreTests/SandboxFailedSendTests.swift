import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("A send whose sandbox fails to start")
struct SandboxFailedSendTests {
  @Test("The message stays in the chat, and Retry sends it again without going through the composer")
  func retryResendsTheHeldMessage() async throws {
    let client = FailingSandboxServerClient()
    let controller = makeController(client: client)

    await controller.send()
    let held = try #require(controller.transcriptProjectionInput.pendingUserMessage)
    let failure = controller.sandboxStartFailure
    let composerAfterFailure = controller.composerText
    controller.retrySandboxStart()
    await client.creates.wait(for: 2)
    await awaitObserved { controller.sandboxStartFailure != nil }

    #expect(held.text == "Which machine are you running on?")
    #expect(failure == "Couldn't connect to the dev cloud")
    #expect(composerAfterFailure.isEmpty)
    #expect(controller.pendingUserMessage == nil)
    #expect(controller.transcriptProjectionInput.pendingUserMessage?.id == held.id)
    #expect(controller.composerText.isEmpty)
  }

  @Test("Sending something else instead replaces the failed message")
  func newSendReplacesTheHeldMessage() async throws {
    let client = FailingSandboxServerClient()
    let controller = makeController(client: client)
    await controller.send()

    controller.composerText = "Try again on macOS"
    await controller.send()

    #expect(controller.transcriptProjectionInput.pendingUserMessage?.text == "Try again on macOS")
    #expect(controller.composerText.isEmpty)
  }

  private func makeController(client: FailingSandboxServerClient) -> SessionController {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/hello-world"), serverId: "local")
    let controller = SessionController(
      project: project, configCache: ConfigOptionCache(store: InMemoryStore()), serverClient: client)
    controller.harnesses = [
      ServerHarness(
        id: "codex", name: "Codex", symbolName: "sparkle", source: "registry",
        launchKind: "executable", enabled: true, readiness: ServerHarnessReadiness(state: "ready"))
    ]
    controller.selectedHarnessId = "codex"
    controller.configurationValidationState = .ready
    controller.onFirstSend = { _ in }
    controller.sandboxTarget = .tartVM
    controller.composerText = "Which machine are you running on?"
    return controller
  }
}

private final class FailingSandboxServerClient: CodevisorServerClienting, @unchecked Sendable {
  let creates = TestSignal()
  private let lock = NSLock()
  private var created: [String] = []

  func createSandbox(_ request: ServerSandboxRequest) async throws -> ServerSandbox {
    lock.withLock { created.append(request.id) }
    creates.signal()
    return ServerSandbox(id: request.id, vendor: "tart", name: "Tart", state: "creating")
  }

  func sandboxes() async throws -> [ServerSandbox] {
    lock.withLock { created }.map { id in
      ServerSandbox(
        id: id, vendor: "tart", name: "Tart", state: "failed",
        steps: [ServerSandboxSetupStep(stage: "create", startedAt: "2026-10-27T00:00:00.000Z")],
        error: "Couldn't connect to the dev cloud")
    }
  }

  func destroySandbox(id: String) async throws {}

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
