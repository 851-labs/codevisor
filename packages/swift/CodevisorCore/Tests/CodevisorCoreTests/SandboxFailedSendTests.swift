import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorCore

@MainActor
@Suite("A send whose sandbox fails to start")
struct SandboxFailedSendTests {
  @Test("A sandbox the server refuses goes back to New Chat with the message, its attachments, and the reason")
  func refusedSandboxReturnsToNewChat() async throws {
    let reason = "Pause after must be one of 15 min, 30 min, 1 hr, 4 hr"
    let client = FailingSandboxServerClient(refusal: .httpStatus(400, #"{"error":"\#(reason)"}"#))
    let controller = makeController(client: client)
    controller.attachments.restore([try attachment(in: controller.attachmentFiles)])
    var didFailSetup = false
    controller.onSetupFailed = { didFailSetup = true }

    await controller.send()
    await awaitObserved { controller.status == .failed(reason) }

    #expect(didFailSetup)
    #expect(controller.shouldShowNewChatComposer)
    #expect(!controller.hasAcceptedFirstSend)
    #expect(controller.transcriptProjectionInput.pendingUserMessage == nil)
    #expect(controller.setupPhases.isEmpty)
    #expect(controller.composerText == "Which machine are you running on?")
    #expect(controller.composerAttachments.map(\.name) == ["note.txt"])
  }

  @Test("Sending again after a refused sandbox asks for a new sandbox and comes back the same way")
  func sendingAgainStartsANewSandbox() async throws {
    let refused = SessionController.Status.failed("Tart isn't running")
    let client = FailingSandboxServerClient(refusal: .httpStatus(503, #"{"error":"Tart isn't running"}"#))
    let controller = makeController(client: client)
    await controller.send()
    await awaitObserved { controller.status == refused }

    await controller.send()
    await client.creates.wait(for: 2)
    await awaitObserved { controller.status == refused }

    #expect(controller.shouldShowNewChatComposer)
    #expect(controller.transcriptProjectionInput.pendingUserMessage == nil)
    #expect(controller.composerText == "Which machine are you running on?")
  }

  @Test("A sandbox that starts but can't be reached also goes back to New Chat with the reason")
  func connectFailureReturnsToNewChat() async throws {
    let client = FailingSandboxServerClient(state: "ready")
    let controller = makeController(client: client)

    await controller.send()
    await awaitObserved { controller.status == .failed("The Tart VM didn't report where its project is") }

    #expect(controller.shouldShowNewChatComposer)
    #expect(controller.transcriptProjectionInput.pendingUserMessage == nil)
    #expect(controller.composerText == "Which machine are you running on?")
  }

  @Test("A worktree that fails on the started sandbox keeps the chat and its steps, and Try Again tries it again")
  func worktreeFailureOnTheSandboxKeepsTheChat() async throws {
    let client = FailingSandboxServerClient()
    let controller = makeController(client: client)
    controller.sandboxTarget = nil
    controller.wantsNewWorktree = true
    var connected = SandboxSetupSteps(target: .tartVM, projectName: "hello-world").phase(.connect)
    connected.succeed()
    controller.beginSetupPhase(connected)

    await controller.send()
    let held = try #require(controller.transcriptProjectionInput.pendingUserMessage)
    let failed = TranscriptDelivery.failed(reason: "fatal: could not create work tree dir")
    await awaitObserved { controller.transcriptProjectionInput.deliveries[held.id] == failed }
    let worktree = controller.setupPhases.first { $0.id == SessionSetupPhase.worktreePhaseId }
    await controller.retryUnsentMessage(id: held.id)
    await client.worktrees.wait(for: 2)

    #expect(worktree?.failureMessage == "fatal: could not create work tree dir")
    #expect(!controller.shouldShowNewChatComposer)
    #expect(controller.setupPhases.contains { $0.id == connected.id })
    #expect(held.text == "Which machine are you running on?")
  }

  @Test("A chat headed for a sandbox never sets up a worktree, even when a project pick asks for one afterwards")
  func sandboxChatsRefuseWorktrees() {
    let controller = makeController(client: FailingSandboxServerClient())

    controller.wantsNewWorktree = true

    #expect(!controller.wantsNewWorktree)
  }

  private func attachment(in files: ComposerAttachmentFileStore) throws -> ComposerAttachment {
    let id = UUID()
    return ComposerAttachment(
      id: id, name: "note.txt", mimeType: "text/plain", kind: .file,
      fileURL: try files.stage(data: Data("note".utf8), id: id, name: "note.txt"),
      state: .uploaded(
        ServerAttachmentRef(fileId: "file-1", name: "note.txt", mimeType: "text/plain", sizeBytes: 4, kind: .file))
    )
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
  let worktrees = TestSignal()
  private let state: String
  private let refusal: CodevisorServerClientError?
  private let lock = NSLock()
  private var created: [String] = []

  init(state: String = "failed", refusal: CodevisorServerClientError? = nil) {
    self.state = state
    self.refusal = refusal
  }

  func createSandbox(_ request: ServerSandboxRequest) async throws -> ServerSandbox {
    creates.signal()
    if let refusal { throw refusal }
    lock.withLock { created.append(request.id) }
    return ServerSandbox(id: request.id, vendor: "tart", name: "Tart", state: "creating")
  }

  func sandboxes() async throws -> [ServerSandbox] {
    lock.withLock { created }.map { id in
      ServerSandbox(
        id: id, vendor: "tart", name: "Tart", state: state,
        steps: [ServerSandboxSetupStep(stage: "create", startedAt: "2026-10-27T00:00:00.000Z")],
        error: state == "failed" ? "Couldn't connect to the dev cloud" : nil)
    }
  }

  func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
    worktrees.signal()
    throw CodevisorServerClientError.httpStatus(422, #"{"error":"fatal: could not create work tree dir"}"#)
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
