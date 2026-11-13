import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Checking a machine can clone the project before a new chat sends")
struct ProjectCloneAccessCheckTests {
  @Test("Holds the send while the machine checks, then sends once it can reach the repository")
  func sendsOnceReachable() async throws {
    let client = AccessServerClient(answers: [ServerProjectCloneAccess(ok: true)])
    let (setup, plan) = try makeSetup(client: client)
    let access = ProjectCloneAccessCheck()
    var resubmits = 0

    access.check(plan, failuresOn: setup) { resubmits += 1 }
    let checkingWhileHeld = access.isChecking
    await awaitObserved { !access.isChecking }

    #expect(checkingWhileHeld)
    #expect(resubmits == 1)
    #expect(access.isVerified(plan))
    #expect(setup.phase == .idle)
    #expect(client.checkedUrls == ["git@github.com:acme/widget.git"])
  }

  @Test("Signs in instead of sending when the machine can't authenticate, then checks again")
  func signsInBeforeSending() async throws {
    let client = AccessServerClient(answers: [ServerProjectCloneAccess(ok: false, code: "auth_failed")])
    let (setup, plan) = try makeSetup(client: client)
    let access = ProjectCloneAccessCheck()
    var resubmits = 0

    access.check(plan, failuresOn: setup) { resubmits += 1 }
    await awaitObserved { !access.isChecking }
    let shown = setup.phase
    setup.retry()

    guard case let .signingIn(shownPlan, _) = shown else {
      Issue.record("Expected GitHub sign-in before the send, got \(shown)")
      return
    }
    #expect(shownPlan == plan)
    #expect(!access.isVerified(plan))
    #expect(resubmits == 1)
    #expect(setup.phase == .idle)
  }

  @Test("Sends without asking a machine that can't check access")
  func sendsWithoutCheckingOlderMachines() async throws {
    let client = AccessServerClient(answers: [])
    let (setup, plan) = try makeSetup(client: client, checksAccess: false)
    let access = ProjectCloneAccessCheck()
    var resubmits = 0

    access.check(plan, failuresOn: setup) { resubmits += 1 }
    await awaitObserved { !access.isChecking }

    #expect(resubmits == 1)
    #expect(access.isVerified(plan))
    #expect(client.checkedUrls.isEmpty)
  }

  private func makeSetup(
    client: AccessServerClient, checksAccess: Bool = true
  ) throws -> (ProjectMachineSetup, ProjectMachineSetup.Plan) {
    let setup = ProjectMachineSetup(
      clientFor: { _ in client },
      machineName: { $0 == "mac" ? "MacBook" : "Studio" },
      isReachable: { _ in false },
      checksCloneAccess: { _ in checksAccess },
      adopt: { _ in }
    )
    let onMac = Project(
      serverId: "mac", name: "widget", repoUrl: "git@github.com:acme/widget.git",
      repoKey: "github.com/acme/widget")
    let group = try #require(ProjectGroup.grouping([onMac]).first)
    let plan = try #require(setup.clonePlan(group: group, targetServerId: "studio", preferredSource: nil))
    return (setup, plan)
  }
}

private final class AccessServerClient: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [ServerProjectCloneAccess]
  private var urls: [String] = []

  init(answers: [ServerProjectCloneAccess]) {
    self.answers = answers
  }

  var checkedUrls: [String] { lock.withLock { urls } }

  func projectCloneAccess(url: String) async throws -> ServerProjectCloneAccess {
    lock.withLock {
      urls.append(url)
      return answers.removeFirst()
    }
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
