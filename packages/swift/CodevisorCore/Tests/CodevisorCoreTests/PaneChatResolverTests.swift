import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Chat panes on other machines")
struct PaneChatResolverTests {
  private let sessionId = UUID()
  private let studio = accountMachine("studio", name: "Mac Studio")

  private func split(on machineId: String?) -> PaneDescriptorState {
    PaneDescriptorState(
      id: UUID(), kind: .childAgent, name: "Child", terminalKey: "child", chatSessionId: sessionId,
      chatMachineId: machineId)
  }

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

  private func machineServing(_ chat: PaneChat) -> String? {
    guard case let .ready(session, project) = chat, session.serverId == project.serverId else { return nil }
    return session.serverId
  }

  @Test("A child agent's split loads its chat from the child's machine, and an older split from the parent's")
  func resolvesThroughTheChildsMachine() async {
    let machines = await machines(listingChatOn: ["local", studio.id])
    let resolver = PaneChatResolver(projectList: machines.projectList, machines: machines)

    #expect(machineServing(resolver.chat(sessionId, in: split(on: studio.id), hostedOn: "local")) == studio.id)
    #expect(machineServing(resolver.chat(sessionId, in: split(on: nil), hostedOn: "local")) == "local")
  }

  @Test("A child agent's split says its machine is offline, not that the chat is gone, until it's back")
  func offlineMachine() async {
    let machines = await machines(listingChatOn: [studio.id])
    let resolver = PaneChatResolver(projectList: machines.projectList, machines: machines)
    machines.markFailed(for: studio.id, message: "Unreachable")
    machines.connection(for: studio.id).status = MachineStatus(isReachable: false, label: "Unreachable")

    #expect(
      resolver.chat(sessionId, in: split(on: studio.id), hostedOn: "local")
        == .offline(PaneChatMachine(id: studio.id, name: "Mac Studio")))

    machines.markReady(for: studio.id)

    #expect(machineServing(resolver.chat(sessionId, in: split(on: studio.id), hostedOn: "local")) == studio.id)
  }

  @Test("A child agent's split keeps its chat's machine through a relaunch")
  func machineSurvivesRelaunch() throws {
    let persistence = InMemoryStore()
    let pane = split(on: studio.id)
    let tab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id)))
    let workspaceId = UUID()
    DeviceLayoutStore(store: persistence).setLayout(
      DeviceLayout(serverId: "local", tabs: [tab], selectedTabId: tab.id), for: workspaceId)
    PersistenceEncoding.drain()

    let restored = try #require(DeviceLayoutStore(store: persistence).layout(for: workspaceId))

    #expect(restored.tabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }.map(\.chatMachineId) == [studio.id])
  }
}
