import ACPKit
import CodevisorProtocol
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Session controller skills")
struct SessionControllerSkillsTests {
  @Test("A draft offers its project's inspected skills and the server's Codevisor skills, behind the harness prefix")
  func draftSkills() async throws {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { cwd in
      var capability = Self.codexCapability()
      // Project skills are specific to the inspected directory.
      if cwd == "/tmp/machine-a" {
        capability.skills = SessionSkills(
          skills: [SessionSkill(name: "review", invocation: "$review", source: .project)],
          invocationPrefix: "$"
        )
      }
      return ServerCapabilities(harnesses: [capability])
    }
    let requests = ComposerSkillRequests()
    client.composerSkillsHandler = { projectId, sessionId in
      await requests.record(projectId, sessionId)
      return [
        ServerComposerSkill(name: "browser-use", description: "Browse the web", builtin: true),
        ServerComposerSkill(name: "deploy", description: "Ship"),
      ]
    }
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/machine-a"), serverId: "machine-a")
    let controller = SessionController(
      project: project,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client
    )

    await controller.prepare()
    await controller.refreshCodevisorSkills()?.value

    #expect(await requests.all == [ComposerSkillRequest(projectId: project.id, sessionId: nil)])
    #expect(
      controller.composerSkills == [
        SessionSkill(
          name: "browser-use", description: "Browse the web", invocation: "$browser-use", source: .codevisor),
        SessionSkill(name: "deploy", description: "Ship", invocation: "$deploy", source: .codevisor),
        SessionSkill(name: "review", invocation: "$review", source: .project),
      ])
  }

  @Test("A live chat asks with its session, and chats in different projects keep their own lists")
  func liveChatScope() async throws {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    let draftProject = Project.fromFolder(URL(fileURLWithPath: "/tmp/draft"), serverId: "m")
    let chatProject = Project.fromFolder(URL(fileURLWithPath: "/tmp/chat"), serverId: "m")
    let session = ChatSession(projectId: chatProject.id, serverId: "m", title: "Live chat")
    let requests = ComposerSkillRequests()
    client.composerSkillsHandler = { projectId, sessionId in
      await requests.record(projectId, sessionId)
      return projectId == chatProject.id
        ? [ServerComposerSkill(name: "browser-use", builtin: true)]
        : [ServerComposerSkill(name: "deploy")]
    }
    let cache = ConfigOptionCache(store: InMemoryStore())
    let draft = SessionController(project: draftProject, configCache: cache, serverClient: client)
    let chat = SessionController(project: chatProject, configCache: cache, serverClient: client)
    chat.serverSession = session

    await draft.refreshCodevisorSkills()?.value
    await chat.refreshCodevisorSkills()?.value

    #expect(
      await requests.all == [
        ComposerSkillRequest(projectId: draftProject.id, sessionId: nil),
        ComposerSkillRequest(projectId: chatProject.id, sessionId: session.id),
      ])
    #expect(draft.composerSkills.map(\.invocation) == ["/deploy"])
    #expect(chat.composerSkills.map(\.invocation) == ["/browser-use"])
  }

  @Test("Against a server without the endpoint, valid unreserved store skills stand in")
  func olderServerFallback() async throws {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.skillsList = ServerSkillsList(skills: [
      ServerSkill(name: "Deploy it", directoryName: "deploy", description: "Ship", path: "/s/deploy"),
      ServerSkill(name: "Broken", directoryName: "broken", path: "/s/broken", invalid: true),
      ServerSkill(name: "Browser", directoryName: "browser-use", path: "/s/browser-use"),
    ])
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/old"), serverId: "old"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client
    )

    await controller.refreshCodevisorSkills()?.value

    #expect(
      controller.composerSkills == [
        SessionSkill(name: "deploy", description: "Ship", invocation: "/deploy", source: .codevisor)
      ])
  }

  @Test("A No project draft offers the machine's default Codevisor skills")
  func placeholderProject() async throws {
    let client = SyncFakeServerClient(projects: [], sessions: [])
    let requests = ComposerSkillRequests()
    client.composerSkillsHandler = { projectId, sessionId in
      await requests.record(projectId, sessionId)
      return [ServerComposerSkill(name: "browser-use", builtin: true)]
    }
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: "m"),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client
    )

    await controller.refreshCodevisorSkills()?.value

    #expect(await requests.all == [ComposerSkillRequest(projectId: nil, sessionId: nil)])
    #expect(controller.composerSkills.map(\.invocation) == ["/browser-use"])
  }

  private nonisolated static func codexCapability() -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: ServerHarness(
        id: "codex",
        name: "Codex",
        symbolName: "terminal",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: ServerHarnessReadiness(state: "ready")
      ),
      configOptions: []
    )
  }
}

private struct ComposerSkillRequest: Equatable {
  let projectId: UUID?
  let sessionId: UUID?
}

private actor ComposerSkillRequests {
  private(set) var all: [ComposerSkillRequest] = []

  func record(_ projectId: UUID?, _ sessionId: UUID?) {
    all.append(ComposerSkillRequest(projectId: projectId, sessionId: sessionId))
  }
}
