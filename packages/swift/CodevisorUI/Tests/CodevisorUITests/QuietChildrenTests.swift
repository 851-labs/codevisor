import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct QuietChildrenTests {
  private let project = Project(id: UUID(), serverId: "studio", name: "codevisor")

  private func item(parent: WorkspaceSidebarItem? = nil) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: UUID(), serverId: project.serverId, projectId: project.id, routingChatIds: [],
      parent: parent.map { WorkspaceParentLink(workspaceId: $0.id, linkedAt: .distantPast, isAgentMade: false) })
  }

  private func quietChildren(
    _ items: [WorkspaceSidebarItem], pinned: [WorkspaceSidebarItem] = [], collapsing collapsed: [WorkspaceSidebarItem]
  ) -> QuietChildren {
    QuietChildren(
      tree: SidebarWorkspaceTree(items, pinnedIDs: pinned.map(\.id.uuidString)),
      disclosure: SidebarChildDisclosure(collapsed: collapsed.map { SidebarRows.childrenGroupID($0.id) }, expanded: []))
  }

  @Test("A workspace is quiet while any ancestor's children are collapsed, and a top-level row never is")
  func quietUnderCollapsedAncestors() {
    let parent = item()
    let child = item(parent: parent)
    let grandchild = item(parent: child)
    let all = [parent, child, grandchild]

    func quiet(collapsing collapsed: [WorkspaceSidebarItem]) -> [Bool] {
      let quiet = quietChildren(all, collapsing: collapsed)
      return all.map { quiet.contains($0.id) }
    }

    #expect(quiet(collapsing: []) == [false, false, false])
    #expect(quiet(collapsing: [parent]) == [false, true, true])
    #expect(quiet(collapsing: [child]) == [false, false, true])
    #expect(quiet(collapsing: [grandchild]) == [false, false, false])
  }

  @Test("A child the sidebar lists at the top level, like one pinned apart from its parent, is never quiet")
  func topLevelChildIsNeverQuiet() {
    let parent = item()
    let pinnedChild = item(parent: parent)

    let quiet = quietChildren([parent, pinnedChild], pinned: [pinnedChild], collapsing: [parent])

    #expect(!quiet.contains(pinnedChild.id))
  }

  @Test("A quiet child's attention isn't announced unless a window has its chat open; others always are")
  func announcementsSkipQuietChildrenThatArentOpen() {
    let parent = item()
    let child = item(parent: parent)
    let quiet = quietChildren([parent, child], collapsing: [parent])
    let expanded = quietChildren([parent, child], collapsing: [])
    let session = SessionAttentionFocus(serverId: project.serverId, sessionId: UUID())

    #expect(!quiet.announces(session, workspaceId: child.id, openSessions: []))
    #expect(quiet.announces(session, workspaceId: child.id, openSessions: [session]))
    #expect(quiet.announces(session, workspaceId: parent.id, openSessions: []))
    #expect(quiet.announces(session, workspaceId: nil, openSessions: []))
    #expect(expanded.announces(session, workspaceId: child.id, openSessions: []))
  }
}
