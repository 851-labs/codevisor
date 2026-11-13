import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Chat pane availability")
struct PaneChatResolverTests {
  private let sessionId = UUID()
  private let studio = accountMachine("studio", name: "Mac Studio")

  private func machines(listingChatOn machineIds: [String]) async -> MachineController {
    let fixture = NavigationFixture()
    for machineId in machineIds {
      let project = Project.fromFolder(URL(fileURLWithPath: "/src/\(machineId)"), serverId: machineId)
      let chat = ChatSession(id: sessionId, projectId: project.id, serverId: machineId, title: machineId)
      await fixture.install(machineId: machineId, projects: [project], sessions: [chat])
    }
    let machines = MachineController(
      store: InMemoryStore(), projectList: fixture.projectList,
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) })
    signIn(machines, machines: [studio])
    return machines
  }

  @Test(
    "A chat pane whose chat hasn't loaded says its machine is offline, and only says the chat is gone once it's back"
  )
  func offlineMachine() async {
    let machines = await machines(listingChatOn: [])
    let resolver = PaneChatResolver(projectList: machines.projectList, machines: machines)
    machines.markFailed(for: studio.id, message: "Unreachable")
    machines.connection(for: studio.id).status = MachineStatus(isReachable: false, label: "Unreachable")

    #expect(resolver.chat(sessionId, on: studio.id) == .offline(PaneChatMachine(id: studio.id, name: "Mac Studio")))

    machines.markReady(for: studio.id)

    #expect(resolver.chat(sessionId, on: studio.id) == .missing)
  }

  @Test("A chat pane shows its chat from whichever machine runs it, not only the workspace's machine")
  func chatOnAnotherMachine() async {
    let machines = await machines(listingChatOn: ["laptop"])
    let resolver = PaneChatResolver(projectList: machines.projectList, machines: machines)

    guard case let .ready(chat, project) = resolver.chat(sessionId, on: studio.id) else {
      Issue.record("The chat on the laptop was not found")
      return
    }

    #expect(chat.serverId == "laptop")
    #expect(project.serverId == "laptop")
  }
}
