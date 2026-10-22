import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Starting a chat in goal mode")
struct SessionControllerGoalStartTests {
  enum Submission: Sendable {
    case send
    case goal
  }

  enum Target: CaseIterable, Sendable {
    case gitProject
    case scratchProject
    case noProject

    var expectedSetup: SetupTrace {
      switch self {
      case .gitProject:
        SetupTrace(worktrees: 1, scratchFolders: 0, phasesWhileStarting: ["worktree"], inScratchFolder: false)
      case .scratchProject:
        SetupTrace(worktrees: 0, scratchFolders: 0, phasesWhileStarting: [], inScratchFolder: true)
      case .noProject:
        SetupTrace(worktrees: 0, scratchFolders: 1, phasesWhileStarting: [], inScratchFolder: true)
      }
    }
  }

  struct SetupTrace: Equatable {
    var worktrees: Int
    var scratchFolders: Int
    var phasesWhileStarting: [String]
    var inScratchFolder: Bool
  }

  @Test(
    "A goal sets up its chat exactly like a send, then sets the goal instead of prompting",
    arguments: Target.allCases)
  func goalStartsLikeSend(target: Target) async throws {
    let sent = try Fixture(target: target)
    let goal = try Fixture(target: target)

    let sendSetup = await sent.start(with: .send)
    let goalSetup = await goal.start(with: .goal)

    #expect(sendSetup == target.expectedSetup)
    #expect(goalSetup == sendSetup)
    #expect(goal.promotions == [Fixture.objective])
    #expect(goal.client.goalUpdates.map(\.0) == [Fixture.objective])
    #expect(goal.client.promptedTexts.isEmpty)
    #expect(goal.controller.goal?.objective == Fixture.objective)
    #expect(!goal.controller.isGoalComposerArmed)
    #expect(goal.controller.composerText.isEmpty)
    #expect(sent.client.promptedTexts == [Fixture.objective])
    #expect(sent.client.goalUpdates.isEmpty)
  }

  @Test("A goal whose agent fails to start returns to New Chat with the goal draft armed")
  func failedStartRestoresGoalDraft() async throws {
    let fixture = try Fixture(target: .gitProject)
    fixture.client.openSessionFailure = .httpStatus(503, "Setup failed")

    fixture.controller.isGoalComposerArmed = true
    await fixture.controller.submitGoalFromComposer()

    #expect(fixture.controller.shouldShowNewChatComposer)
    #expect(fixture.controller.composerText == Fixture.objective)
    #expect(fixture.controller.isGoalComposerArmed)
    #expect(fixture.controller.draftGoal == nil)
    #expect(fixture.controller.setupPhases.isEmpty)
    #expect(fixture.client.goalUpdates.isEmpty)
  }

  @MainActor
  private final class Fixture {
    static let objective = "Ship the release"

    let sessionID = UUID()
    let client: FakeSessionServerClient
    let controller: SessionController
    var promotions: [String] = []

    init(target: Target) throws {
      let project = Self.project(for: target)
      client = FakeSessionServerClient(sessionId: sessionID)
      client.echoOnPrompt = false
      client.openSessionResponse = try Self.openResponse(sessionID: sessionID, projectID: project.id)
      controller = SessionController(
        project: project, configCache: ConfigOptionCache(store: InMemoryStore()), serverClient: client
      )
      controller.harnesses = [
        ServerHarness(
          id: "codex", name: "Codex", symbolName: "sparkle", source: "registry",
          launchKind: "executable", enabled: true, readiness: ServerHarnessReadiness(state: "ready")
        )
      ]
      controller.selectedHarnessId = "codex"
      controller.configurationValidationState = .ready
      controller.wantsNewWorktree = true
      controller.composerText = Self.objective
      controller.onFirstSend = { [unowned self] text in
        promotions.append(text)
        controller.serverSession = ChatSession(
          id: sessionID, projectId: controller.project.id, serverId: controller.project.serverId,
          harnessId: "codex", title: text, createdAt: Date(timeIntervalSince1970: 0)
        )
      }
    }

    func start(with submission: Submission) async -> SetupTrace {
      let (gate, release) = AsyncStream.makeStream(of: Void.self)
      client.openSessionGate = gate
      let started = Task { await submit(submission) }
      await client.openSessionRequests.wait()
      let phases = controller.setupPhases.map(\.id)
      release.finish()
      await started.value
      if submission == .send { await client.promptRequests.wait() }
      controller.model?.shutdown()
      return SetupTrace(
        worktrees: client.setupRequests.worktreeProjectIds.count,
        scratchFolders: client.setupRequests.scratchProjectIds.count,
        phasesWhileStarting: phases,
        inScratchFolder: controller.project.isScratch
      )
    }

    private func submit(_ submission: Submission) async {
      switch submission {
      case .send:
        await controller.send()
      case .goal:
        controller.isGoalComposerArmed = true
        await controller.submitGoalFromComposer()
      }
    }

    private static func project(for target: Target) -> Project {
      switch target {
      case .gitProject:
        var project = Project.fromFolder(URL(fileURLWithPath: "/fixture/repo"))
        project.locations[0].isGitRepository = true
        return project
      case .scratchProject:
        var project = Project.fromFolder(URL(fileURLWithPath: "/fixture/workspaces/burrito"))
        project.isScratch = true
        return project
      case .noProject:
        return .runTargetPlaceholder(serverId: "local")
      }
    }

    private static func openResponse(sessionID: UUID, projectID: UUID) throws -> ServerSessionOpenResponse {
      try JSONDecoder().decode(
        ServerSessionOpenResponse.self,
        from: JSONSerialization.data(withJSONObject: [
          "session": [
            "id": sessionID.uuidString, "projectId": projectID.uuidString,
            "serverId": "local", "harnessId": "codex", "title": "Draft",
            "origin": "codevisor", "createdAt": "2026-10-22T12:00:00Z",
          ],
          "transcript": [
            "items": [], "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false,
            "eventCursor": 0,
          ],
        ])
      )
    }
  }
}
