import CodevisorCore
import CoreGraphics
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarWorkspaceDropsTests {
  private let studio = Project(id: UUID(), serverId: "studio", name: "codevisor")
  private let linux = Project(id: UUID(), serverId: "linux", name: "api")
  private let focus = CustomSection(id: UUID(), name: "Focus", position: "4000000000008")
  private let later = CustomSection(id: UUID(), name: "Later", position: "8000000000008")

  private func item(_ project: Project, parent: UUID? = nil) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: UUID(), serverId: project.serverId, projectId: project.id, routingChatIds: [],
      parent: parent.map { WorkspaceParentLink(workspaceId: $0, linkedAt: .distantPast, isQuiet: false) })
  }

  private func rows(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping = .flat, pinned: [UUID] = [],
    membership: [UUID: UUID] = [:]
  ) -> [SidebarRow] {
    let tree = SidebarWorkspaceTree(items, pinnedIDs: pinned.map(\.uuidString))
    let groups = SidebarWorkspaceGroup.groups(
      tree.roots, grouping: grouping, pinnedIDs: pinned.map(\.uuidString), projects: [studio, linux],
      defaultServerId: "studio", sections: [focus, later], membership: membership
    ) { serverId in
      SidebarMachineGroup(
        key: serverId, orderKey: serverId,
        heading: SidebarWorkspaceGroup.Heading(title: serverId, icon: .system("desktopcomputer")))
    }
    return SidebarRows.derive(SidebarRows.State(groups: groups, children: tree.children))
  }

  private func stackedFrames(_ rows: [SidebarRow]) -> [SidebarRowID: CGRect] {
    Dictionary(
      uniqueKeysWithValues: rows.enumerated().map { index, row in
        (row.id, CGRect(x: 0, y: CGFloat(index) * 40, width: 200, height: 40))
      })
  }

  @Test("A sectioned workspace can drop at any spot in another section or in the list, never above the first header")
  func sectionedWorkspaceDropsAnywhere() throws {
    let (a, b, c, d, e) = (item(studio), item(studio), item(studio), item(studio), item(studio))
    let rows = rows([a, b, c, d, e], membership: [a.id: focus.id, b.id: later.id, c.id: later.id])
    let region = try #require(SidebarWorkspaceDrops.region(dragging: b.id, in: rows))

    #expect(
      region.slots.map(\.row) == [
        .section(.custom(focus.id)), .workspace(a.id), .section(.custom(later.id)), .workspace(b.id),
        .workspace(c.id), .section(.list), .workspace(d.id), .workspace(e.id),
      ])
    #expect(region.placement(insertingAt: 6, excluding: b.id) == SidebarPlacement(section: nil, after: d.id))
    #expect(region.placement(insertingAt: 2, excluding: b.id) == SidebarPlacement(section: focus.id, after: a.id))
    #expect(region.siblings(placing: b.id, at: SidebarPlacement(section: nil, after: d.id)) == [d.id, b.id, e.id])
    #expect(region.placement(dropping: b.id, below: []) == SidebarPlacement(section: focus.id, after: nil))
  }

  @Test("Hovering another section's header targets the header; hovering a gap targets that insertion line")
  func dragTargets() throws {
    let (a, b, d) = (item(studio), item(studio), item(studio))
    let rows = rows([a, b, d], membership: [a.id: focus.id, b.id: later.id])
    let region = try #require(SidebarWorkspaceDrops.region(dragging: b.id, in: rows))
    let frames = stackedFrames(rows)
    func target(atY y: CGFloat) -> SidebarItemDropTarget? {
      region.target(dragging: b.id, ghost: CGRect(x: 0, y: y - 20, width: 200, height: 40), frames: frames)
    }

    let listHeader = try #require(frames[.section(.list)])
    #expect(target(atY: listHeader.midY) == .header(section: nil))
    #expect(target(atY: frames[.workspace(d.id)]!.maxY - 1) == .insertion(5))
    #expect(target(atY: frames[.workspace(b.id)]!.midY) == nil)
    #expect(target(atY: frames[.section(.custom(later.id))]!.midY) == .insertion(2))
  }

  @Test(
    "In a grouped list a workspace reorders only within its own group; from a section it can drop on the list header")
  func groupedListKeepsGroups() throws {
    let (mac, box, sectioned) = (item(studio), item(linux), item(studio))
    let rows = rows([mac, box, sectioned], .machine, membership: [sectioned.id: focus.id])

    let fromList = try #require(SidebarWorkspaceDrops.region(dragging: mac.id, in: rows))
    let fromSection = try #require(SidebarWorkspaceDrops.region(dragging: sectioned.id, in: rows))

    #expect(fromList.slots.compactMap(\.itemID) == [sectioned.id, mac.id])
    #expect(fromSection.slots.compactMap(\.itemID) == [sectioned.id])
    #expect(fromSection.slots.last?.row == .section(.list))
  }

  @Test("Pinned and nested workspaces reorder in place without changing their section")
  func pinnedAndNestedStayPut() throws {
    let (pinnedA, pinnedB, parent) = (item(studio), item(studio), item(studio))
    let (childA, childB) = (item(studio, parent: parent.id), item(studio, parent: parent.id))
    let rows = rows(
      [pinnedA, pinnedB, parent, childA, childB], pinned: [pinnedA.id, pinnedB.id], membership: [pinnedB.id: later.id])

    let pinned = try #require(SidebarWorkspaceDrops.region(dragging: pinnedB.id, in: rows))
    let nested = try #require(SidebarWorkspaceDrops.region(dragging: childB.id, in: rows))

    #expect(pinned.slots.compactMap(\.itemID) == [pinnedA.id, pinnedB.id])
    #expect(pinned.placement(insertingAt: 0, excluding: pinnedB.id) == SidebarPlacement(section: nil, after: nil))
    #expect(!pinned.movesSections)
    #expect(nested.slots.compactMap(\.itemID) == [childA.id, childB.id])
    #expect(
      nested.siblings(placing: childB.id, at: SidebarPlacement(section: nil, after: nil)) == [childB.id, childA.id])
  }

  @Test("A section header moves as one block with its workspaces")
  func sectionBlocks() throws {
    let (a, b) = (item(studio), item(studio))
    let rows = rows([a, b], membership: [a.id: focus.id, b.id: later.id])
    let blocks = try #require(SidebarWorkspaceDrops.blocks(dragging: .section(.custom(later.id)), in: rows))
    let frames = stackedFrames(rows)

    #expect(blocks.headers == [.section(.custom(focus.id)), .section(.custom(later.id))])
    #expect(blocks.target(dragging: .section(.custom(later.id)), midY: 0, frames: frames) == 0)
    #expect(
      blocks.target(dragging: .section(.custom(later.id)), midY: frames[.workspace(b.id)]!.midY, frames: frames) == nil)
  }
}
