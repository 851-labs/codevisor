import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Sending in a project the machine hasn't cloned yet")
struct ProjectCloneSendTests {
  @Test("The send clones the project inside the worktree step, then sets up the worktree in the clone")
  func clonesThenCreatesTheWorktree() async throws {
    let client = CloningServerClient(outcomes: [.cloned])
    let (controller, request) = try makeController(client: client)
    var clonedWith: (project: Project, phases: [SessionSetupPhase])?
    controller.onProjectCloned = { clonedWith = ($0, controller.setupPhases) }

    await controller.send()
    await client.worktreeRequests.wait(for: 1)

    let cloned = try #require(clonedWith)
    #expect(client.setupRequests.map(\.id) == [request.projectId.uuidString])
    #expect(client.setupRequests.first?.url == "git@github.com:acme/widget.git")
    #expect(cloned.project.id == request.projectId)
    #expect(cloned.phases.map(\.id) == [SessionSetupPhase.worktreePhaseId])
    #expect(cloned.phases.first?.isRunning == true)
    #expect(cloned.phases.first?.logs.map(\.text) == ["Connecting…"])
    #expect(client.worktreeProjectIds == [request.projectId])
  }

  @Test("In the project directory, the clone is the whole project setup step")
  func cloneIsTheProjectSetupStep() async throws {
    let client = CloningServerClient(outcomes: [.cloned])
    let (controller, _) = try makeController(client: client, wantsNewWorktree: false)
    var phases: [SessionSetupPhase] = []
    controller.onProjectCloned = { _ in phases = controller.setupPhases }

    await controller.send()
    await awaitObserved { controller.setupPhases.first?.isSucceeded == true }

    #expect(phases.map(\.completedTitle) == ["Set up project"])
    #expect(phases.first?.isSucceeded == true)
    #expect(client.worktreeProjectIds.isEmpty)
  }

  @Test("A repository the machine can't see keeps the chat and its Not Delivered message, and Retry clones again")
  func cloneFailureHoldsTheSendForRetry() async throws {
    let client = CloningServerClient(outcomes: [.repositoryMissing, .cloned])
    let (controller, request) = try makeController(client: client)

    await controller.send()
    let sent = try #require(controller.transcriptProjectionInput.pendingUserMessage)
    await awaitObserved {
      controller.projectCloneFailureMessage != nil
        && controller.transcriptProjectionInput.deliveries[sent.id]?.isFailed == true
    }
    let failedStep = controller.setupPhases.first { $0.id == SessionSetupPhase.worktreePhaseId }
    let sheet = request.setup.phase
    let held = controller.transcriptProjectionInput.pendingUserMessage
    let failure = controller.projectCloneFailureMessage
    let offersSignIn = controller.projectCloneFailureOffersSignIn
    let showsNewChat = controller.shouldShowNewChatComposer
    let composerText = controller.composerText
    request.setup.retry()
    await client.worktreeRequests.wait(for: 1)

    let message = "acme/widget doesn't exist, or Studio's GitHub account can't see it."
    #expect(failure == message)
    #expect(failedStep?.failureMessage == message)
    #expect(offersSignIn)
    #expect(!showsNewChat)
    #expect(held?.text == "Fix the login bug")
    #expect(composerText.isEmpty)
    guard case let .failed(plan, shown) = sheet else {
      Issue.record("Expected the setup sheet to show the clone failure, got \(sheet)")
      return
    }
    #expect(plan == request.plan)
    #expect(shown.isMissingRepository)
    #expect(client.setupRequests.map(\.id) == [request.projectId.uuidString, request.projectId.uuidString])
    #expect(client.worktreeProjectIds == [request.projectId])
    #expect(request.setup.phase == .idle)
  }

  private func makeController(
    client: CloningServerClient, wantsNewWorktree: Bool = true
  ) throws -> (SessionController, ProjectCloneRequest) {
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: "studio"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client)
    controller.harnesses = [
      ServerHarness(
        id: "codex", name: "Codex", symbolName: "sparkle", source: "registry",
        launchKind: "executable", enabled: true, readiness: ServerHarnessReadiness(state: "ready"))
    ]
    controller.selectedHarnessId = "codex"
    controller.configurationValidationState = .ready
    controller.onFirstSend = { _ in }
    controller.composerText = "Fix the login bug"
    controller.wantsNewWorktree = wantsNewWorktree
    let request = try cloneRequest(client: client)
    controller.projectClone = request
    return (controller, request)
  }

  private func cloneRequest(client: CloningServerClient) throws -> ProjectCloneRequest {
    let setup = ProjectMachineSetup(
      clientFor: { _ in client },
      machineName: { $0 == "mac" ? "MacBook" : "Studio" },
      isReachable: { _ in false },
      adopt: { _ in }
    )
    let onMac = Project(
      serverId: "mac", name: "widget", repoUrl: "git@github.com:acme/widget.git",
      repoKey: "github.com/acme/widget")
    let group = try #require(ProjectGroup.grouping([onMac]).first)
    let plan = try #require(setup.clonePlan(group: group, targetServerId: "studio", preferredSource: nil))
    return ProjectCloneRequest(plan: plan, setup: setup, projectList: nil)
  }
}

private final class CloningServerClient: CodevisorServerClienting, @unchecked Sendable {
  enum Outcome {
    case cloned
    case repositoryMissing
  }

  let worktreeRequests = TestSignal()
  private var outcomes: [Outcome]
  private let lock = NSLock()
  private var requests: [ServerProjectSetupRequest] = []
  private var worktrees: [UUID] = []

  init(outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  var setupRequests: [ServerProjectSetupRequest] { lock.withLock { requests } }
  var worktreeProjectIds: [UUID] { lock.withLock { worktrees } }

  func setUpProjectFromGit(_ request: ServerProjectSetupRequest) async throws -> ServerProject {
    let outcome = lock.withLock {
      requests.append(request)
      return outcomes.removeFirst()
    }
    guard outcome == .cloned else {
      throw CodevisorServerClientError.httpStatus(
        404, #"{"error":"Repository not found","code":"repo_not_found"}"#)
    }
    return clonedProject(id: request.id)
  }

  func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
    lock.withLock { worktrees.append(projectId) }
    worktreeRequests.signal()
    throw CodevisorServerClientError.httpStatus(422, #"{"error":"stop after the worktree request"}"#)
  }

  private func clonedProject(id: String) -> ServerProject {
    ServerProject(
      id: id, name: "widget", origin: .codevisor, createdAt: "2026-10-28T12:00:00.000Z",
      locations: [
        ServerProjectLocation(
          id: "location", projectId: id, serverId: "studio", folderPath: "/Users/me/src/widget",
          createdAt: "2026-10-28T12:00:00.000Z", isGitRepository: true)
      ],
      repoUrl: "git@github.com:acme/widget.git")
  }

  func info() async throws -> ServerInfo {
    ServerInfo(id: "studio", name: "Studio", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
  }
  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    throw CodevisorServerClientError.invalidResponse
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    throw CodevisorServerClientError.invalidResponse
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
