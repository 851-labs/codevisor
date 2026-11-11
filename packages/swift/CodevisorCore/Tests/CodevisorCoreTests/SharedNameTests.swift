import Foundation
import Testing

@testable import CodevisorCore

struct SharedNameTests {
  private let projectId = UUID()

  private func chat(_ title: String) -> ChatSession {
    var chat = ChatSession(projectId: projectId, harnessId: "codex")
    chat.title = title
    return chat
  }

  private func workspace(_ name: String, main: ChatSession) -> Workspace {
    var workspace = Workspace(
      name: name, rootDirectory: nil, serverId: "local", projectId: projectId,
      centerTree: .leaf(PaneGroupState()), createdAt: Date(timeIntervalSince1970: 0),
      isServerSynced: true, sidebarOrderHead: nil)
    workspace.mainSessionId = main.id
    return workspace
  }

  private func records(_ workspaces: [Workspace], _ sessions: [ChatSession]) -> NavigationRecords {
    var records = NavigationRecords(nil)
    records.workspaces = workspaces.map(WorkspaceSyncModel.serverWorkspace(from:))
    records.sessions = sessions
    return records
  }

  @Test("A workspace rename retitles its main chat right away and leaves side chats alone")
  func workspaceRenameRetitlesMainChat() {
    let main = chat("had the orange soda drink for lunch")
    let side = chat("Side question")
    let home = workspace("had the orange soda drink for lunch", main: main)
    var records = records([home], [main, side])

    NavigationOverlay.apply(.renameWorkspace(workspaceId: home.id, name: "macro", hasCustomName: true), to: &records)

    #expect(records.sessions.map(\.title) == ["macro", "Side question"])
  }

  @Test("A main chat rename renames its workspace right away; side chats keep theirs")
  func mainChatRenameRenamesWorkspace() {
    let main = chat("Fix the login bug")
    let side = chat("Side question")
    var records = records([workspace("Fix the login bug", main: main)], [main, side])
    var renamedMain = main
    renamedMain.title = "Lunch log"
    var renamedSide = side
    renamedSide.title = "Another side question"

    for renamed in [renamedMain, renamedSide] {
      NavigationOverlay.apply(.renameSession(renamed), to: &records)
    }

    #expect(records.workspaces.map(\.name) == ["Lunch log"])
    #expect(records.workspaces.map(\.hasCustomName) == [true])
  }

  @Test("The main chat shows its workspace's name, even before it has a title of its own")
  func mainChatShowsWorkspaceName() {
    let main = chat("New Session")
    let side = chat("Side question")
    let home = workspace("quesadilla-5480", main: main)

    #expect(home.title(ofChat: main) == "quesadilla-5480")
    #expect(home.title(ofChat: side) == "Side question")
  }
}
