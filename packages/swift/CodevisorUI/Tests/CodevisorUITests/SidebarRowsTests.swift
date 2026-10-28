import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarRowsTests {
  private let studio = Project(id: UUID(), serverId: "studio", name: "codevisor")
  private let linux = Project(id: UUID(), serverId: "linux", name: "api")
  private let site = Project(id: UUID(), serverId: "studio", name: "site")

  private func item(_ project: Project, parent: WorkspaceSidebarItem? = nil) -> WorkspaceSidebarItem {
    item(project, id: UUID(), parent: parent?.id)
  }

  private func item(_ project: Project, id: UUID, parent: UUID?) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: id, serverId: project.serverId, projectId: project.id, routingChatIds: [], parentWorkspaceId: parent)
  }

  private func groups(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping = .machine, pinned: [UUID] = []
  ) -> [SidebarWorkspaceGroup] {
    SidebarWorkspaceGroup.groups(
      items, grouping: grouping, pinnedIDs: pinned.map(\.uuidString), projects: [studio, linux, site],
      defaultServerId: "studio"
    ) { serverId in SidebarWorkspaceGroup.Heading(title: serverId, systemImage: "desktopcomputer") }
  }

  private func nested(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping = .machine, pinned: [UUID] = [],
    archived: [WorkspaceSidebarItem] = [], archivedVisibleCount: Int = sidebarArchivedPageSize,
    expanded: [WorkspaceSidebarItem] = [],
    expansion: SidebarRows.Expansion = SidebarRows.Expansion(), selecting selected: UUID? = nil
  ) -> Layout {
    let tree = SidebarWorkspaceTree(items, pinnedIDs: pinned.map(\.uuidString))
    var expansion = expansion
    expansion.expandedWorkspaceIDs = Set(expanded.map(\.id))
    return derive(
      SidebarRows.State(
        groups: groups(tree.roots, grouping, pinned: pinned), children: tree.children, archived: archived,
        archivedVisibleCount: archivedVisibleCount, expansion: expansion, selectedWorkspaceID: selected))
  }

  private struct Layout {
    let rows: [SidebarRow]

    var ids: [SidebarRowID] { rows.map(\.id) }

    func depth(of id: UUID) -> Int? {
      row(id)?.depth
    }

    func disclosure(of id: UUID) -> SidebarRow.Disclosure? {
      row(id)?.disclosure
    }

    private func row(_ id: UUID) -> SidebarRow? {
      rows.first { $0.id == .workspace(id) }
    }
  }

  private func derive(_ state: SidebarRows.State) -> Layout {
    Layout(rows: SidebarRows.derive(state))
  }

  @Test("Every section renders in the sidebar's order: pinned, the list header, groups, archived")
  func sectionOrder() {
    let (pinned, onStudio, onLinux) = (item(studio), item(studio), item(linux))
    let archived = [item(studio), item(linux)]

    let layout = derive(
      SidebarRows.State(
        groups: groups([pinned, onStudio, onLinux], pinned: [pinned.id]), archived: archived,
        expansion: SidebarRows.Expansion(archived: true)))

    #expect(
      layout.ids == [
        .section(.pinned), .workspace(pinned.id),
        .section(.list), .group("machine:studio"), .workspace(onStudio.id), .group("machine:linux"),
        .workspace(onLinux.id),
        .section(.archived), .workspace(archived[0].id), .workspace(archived[1].id),
      ])
    #expect(layout.rows.map(\.depth) == [0, 0, 0, 0, 1, 0, 1, 0, 0, 0])
    #expect(
      layout.rows.map(\.section) == [.pinned, .pinned, .list, .list, .list, .list, .list]
        + [.archived, .archived, .archived])
  }

  @Test("A workspace keeps one row id whether it's in a group, Pinned, or in Archived")
  func workspaceIdentitySurvivesEveryMove() {
    let moving = item(studio)
    let other = item(studio)
    let placements: [SidebarRows.State] = [
      SidebarRows.State(groups: groups([moving, other])),
      SidebarRows.State(groups: groups([moving, other], pinned: [moving.id])),
      SidebarRows.State(
        groups: groups([other]), archived: [moving], expansion: SidebarRows.Expansion(archived: true)),
    ]

    for state in placements {
      let ids = derive(state).ids
      #expect(ids.filter { $0 == .workspace(moving.id) }.count == 1)
    }
  }

  @Test("Pinning the selected workspace with Pinned collapsed moves its row instead of replacing it (851-2786)")
  func pinningWithPinnedCollapsedIsAMove() {
    let hidden = item(studio)
    let selected = item(studio)
    let neighbor = item(studio)
    let collapsed = SidebarRows.Expansion(pinned: false)
    func state(pinned: [UUID]) -> SidebarRows.State {
      SidebarRows.State(
        groups: groups([hidden, selected, neighbor], pinned: pinned), expansion: collapsed,
        selectedWorkspaceID: selected.id)
    }

    let before = derive(state(pinned: [hidden.id])).ids
    let after = derive(state(pinned: [hidden.id, selected.id])).ids

    #expect(Set(before) == Set(after))
    #expect(
      before == [
        .section(.pinned), .section(.list), .group("machine:studio"), .workspace(selected.id), .workspace(neighbor.id),
      ])
    #expect(
      after == [
        .section(.pinned), .workspace(selected.id), .section(.list), .group("machine:studio"), .workspace(neighbor.id),
      ])
  }

  @Test("Collapsed sections and groups keep only the selected workspace, at the indent it renders with")
  func collapsedParentsKeepTheSelectedRow() {
    let (pinned, selected, sibling, other) = (item(studio), item(studio), item(studio), item(linux))
    let archived = [item(studio), item(studio)]
    let all = groups([pinned, selected, sibling, other], pinned: [pinned.id])
    func layout(_ expansion: SidebarRows.Expansion, selecting id: UUID?) -> Layout {
      derive(
        SidebarRows.State(groups: all, archived: archived, expansion: expansion, selectedWorkspaceID: id))
    }

    let groupCollapsed = layout(
      SidebarRows.Expansion(pinned: false, collapsedGroupIDs: ["machine:studio"]), selecting: selected.id)
    #expect(
      groupCollapsed.ids == [
        .section(.pinned), .section(.list), .group("machine:studio"), .workspace(selected.id),
        .group("machine:linux"), .workspace(other.id), .section(.archived),
      ])
    #expect(groupCollapsed.depth(of: selected.id) == 1)

    let listCollapsed = layout(SidebarRows.Expansion(list: false), selecting: selected.id)
    #expect(
      listCollapsed.ids == [
        .section(.pinned), .workspace(pinned.id), .section(.list), .workspace(selected.id), .section(.archived),
      ])
    #expect(listCollapsed.depth(of: selected.id) == 0)

    let archivedSelected = layout(SidebarRows.Expansion(list: false), selecting: archived[1].id)
    #expect(archivedSelected.ids.suffix(2) == [.section(.archived), .workspace(archived[1].id)])

    let nothingSelected = layout(SidebarRows.Expansion(pinned: false, list: false), selecting: nil)
    #expect(nothingSelected.ids == [.section(.pinned), .section(.list), .section(.archived)])
  }

  @Test("Flat grouping lists workspaces under the list header with no group rows or indent")
  func flatGroupingHasNoGroupRows() {
    let (first, second) = (item(studio), item(linux))

    let layout = derive(SidebarRows.State(groups: groups([first, second], .flat)))

    #expect(layout.ids == [.section(.list), .workspace(first.id), .workspace(second.id)])
    #expect(layout.rows.map(\.depth) == [0, 0, 0])
  }

  @Test("Archived shows its visible pages, then Show More while more remain")
  func archivedPaging() {
    let archived = (0..<5).map { _ in item(studio) }
    func ids(visibleCount: Int, expanded: Bool = true) -> [SidebarRowID] {
      derive(
        SidebarRows.State(
          groups: groups([]), archived: archived, archivedVisibleCount: visibleCount,
          expansion: SidebarRows.Expansion(archived: expanded))
      ).ids
    }

    #expect(
      ids(visibleCount: 3) == [.section(.list), .section(.archived)] + archived.prefix(3).map { .workspace($0.id) }
        + [.showMoreArchived])
    #expect(ids(visibleCount: 5) == [.section(.list), .section(.archived)] + archived.map { .workspace($0.id) })
    #expect(ids(visibleCount: 3, expanded: false) == [.section(.list), .section(.archived)])
    #expect(derive(SidebarRows.State(groups: groups([]))).ids == [.section(.list)])
  }

  @Test("Row ids stay unique across every combination of grouping, expansion and selection")
  func rowIdsAreUnique() {
    let parent = item(studio)
    let child = item(linux, parent: parent)
    let listed = [parent, item(linux), child, item(studio, parent: child)]
    let archived = [item(studio), item(linux, parent: parent), item(studio)]
    let selections: [UUID?] = [nil, listed[0].id, listed[1].id, listed[3].id, archived[1].id]

    for grouping in SidebarGrouping.allCases {
      for mask in 0..<32 {
        for selected in selections {
          let expansion = SidebarRows.Expansion(
            pinned: mask & 1 != 0, list: mask & 2 != 0, archived: mask & 4 != 0,
            collapsedGroupIDs: mask & 8 != 0 ? ["machine:studio", "machine:linux"] : [])
          let ids = nested(
            listed, grouping, pinned: [listed[0].id], archived: archived, archivedVisibleCount: 2,
            expanded: mask & 16 != 0 ? [parent, child] : [], expansion: expansion, selecting: selected
          ).ids
          #expect(Set(ids).count == ids.count)
          if let selected {
            #expect(ids.contains(.workspace(selected)))
          }
        }
      }
    }
  }

  @Test("Archive selection sections are Pinned, then each group, without Archived")
  func activeWorkspaceSections() {
    let (pinned, first, second, other) = (item(studio), item(studio), item(studio), item(linux))
    let rows = SidebarRows.derive(
      SidebarRows.State(
        groups: groups([pinned, first, second, other], pinned: [pinned.id]),
        archived: [item(studio)], expansion: SidebarRows.Expansion(archived: true)))

    #expect(
      SidebarRows.activeWorkspaceSections(rows).map { $0.map(\.id) } == [
        [pinned.id], [first.id, second.id], [other.id],
      ])
  }

  @Test("Subagent workspaces nest under their parent at any depth, collapsed by default with a child count")
  func nestingIsRecursiveAndCollapsedByDefault() {
    let parent = item(studio)
    let (child, sibling) = (item(studio, parent: parent), item(studio, parent: parent))
    let grandchild = item(studio, parent: child)
    let next = item(studio)
    let all = [parent, child, grandchild, sibling, next]

    let collapsed = nested(all)
    #expect(
      collapsed.ids == [.section(.list), .group("machine:studio"), .workspace(parent.id), .workspace(next.id)])
    #expect(collapsed.disclosure(of: parent.id) == SidebarRow.Disclosure(childCount: 2, isExpanded: false))
    #expect(collapsed.disclosure(of: next.id) == nil)

    let expanded = nested(all, expanded: [parent, child])
    #expect(
      Array(expanded.ids.dropFirst(2))
        == [parent, child, grandchild, sibling, next].map { .workspace($0.id) })
    #expect([parent, child, grandchild, sibling, next].map { expanded.depth(of: $0.id) } == [1, 2, 3, 2, 1])
    #expect(expanded.disclosure(of: child.id) == SidebarRow.Disclosure(childCount: 1, isExpanded: true))
    #expect(expanded.rows.compactMap(\.parentID) == [parent.id, child.id, parent.id])
    #expect(expanded.rows.map(\.nesting) == [0, 0, 0, 1, 2, 1, 0])
  }

  @Test("A child nests under its parent even when it belongs to another group, and its own group drops out")
  func childrenNestAcrossGroups() {
    let parent = item(studio)
    let child = item(site, parent: parent)

    let layout = nested([parent, child], .project, expanded: [parent])

    let headings = layout.rows.filter { if case .group = $0.kind { true } else { false } }
    #expect(headings.map(\.id) == [.group("project:\(ProjectGroup.groupID(for: studio))")])
    #expect(layout.ids.suffix(2) == [.workspace(parent.id), .workspace(child.id)])
    #expect(layout.depth(of: child.id) == 2)
  }

  @Test("Children of unlisted, cyclic or self-referencing parents stay top level")
  func unresolvableParentsStayTopLevel() {
    let (firstID, secondID) = (UUID(), UUID())
    let first = item(studio, id: firstID, parent: secondID)
    let second = item(studio, id: secondID, parent: firstID)
    let underCycle = item(studio, parent: first)
    let orphan = item(studio, id: UUID(), parent: UUID())
    let selfParent = item(studio, id: firstID, parent: firstID)

    let tree = SidebarWorkspaceTree([first, second, underCycle, orphan], pinnedIDs: [])
    #expect(tree.roots.map(\.id) == [first.id, second.id, orphan.id])
    #expect(tree.children == [first.id: [underCycle]])
    #expect(SidebarWorkspaceTree([selfParent], pinnedIDs: []).roots == [selfParent])
  }

  @Test("A collapsed parent, group or section keeps only the selected descendant, at its nested indent")
  func collapsedParentKeepsTheSelectedDescendant() {
    let parent = item(studio)
    let child = item(studio, parent: parent)
    let grandchild = item(studio, parent: child)
    let all = [parent, child, grandchild]

    let parentCollapsed = nested(all, selecting: grandchild.id)
    #expect(parentCollapsed.ids.dropFirst(2) == [.workspace(parent.id), .workspace(grandchild.id)])
    #expect(parentCollapsed.depth(of: grandchild.id) == 3)

    let groupCollapsed = nested(
      all, expanded: [parent, child], expansion: SidebarRows.Expansion(collapsedGroupIDs: ["machine:studio"]),
      selecting: grandchild.id)
    #expect(groupCollapsed.ids == [.section(.list), .group("machine:studio"), .workspace(grandchild.id)])
    #expect(groupCollapsed.depth(of: grandchild.id) == 3)
  }

  @Test("Pinning a child pins just that one; a pinned parent keeps its unpinned children")
  func pinnedChildrenAndParents() {
    let parent = item(studio)
    let (pinnedChild, child) = (item(studio, parent: parent), item(studio, parent: parent))

    let childPinned = nested([parent, pinnedChild, child], pinned: [pinnedChild.id], expanded: [parent])
    #expect(
      childPinned.ids == [
        .section(.pinned), .workspace(pinnedChild.id), .section(.list), .group("machine:studio"),
        .workspace(parent.id), .workspace(child.id),
      ])
    #expect(childPinned.disclosure(of: parent.id)?.childCount == 1)

    let parentPinned = nested([parent, pinnedChild, child], pinned: [parent.id], expanded: [parent])
    #expect(
      parentPinned.ids == [.section(.pinned), .workspace(parent.id), .workspace(pinnedChild.id), .workspace(child.id)]
        + [.section(.list)])
    #expect(parentPinned.depth(of: child.id) == 1)
  }

  @Test("Archived children list flat in Archived, and an archived parent leaves its children at the top level")
  func archivedChildrenAreFlat() {
    let parent = item(studio)
    let archivedChild = item(studio, parent: parent)
    let liveChild = item(studio, parent: archivedChild)

    let layout = nested(
      [parent], archived: [archivedChild], expanded: [parent], expansion: SidebarRows.Expansion(archived: true))
    #expect(layout.disclosure(of: parent.id) == nil)
    #expect(layout.depth(of: archivedChild.id) == 0)

    let orphaned = nested([liveChild], archived: [archivedChild])
    #expect(orphaned.ids == [.section(.list), .group("machine:studio"), .workspace(liveChild.id), .section(.archived)])
  }

  @Test("Stepping and archive-next walk nested rows depth first, inside their parent's section")
  func nestedRowsStepDepthFirst() {
    let parent = item(studio)
    let child = item(site, parent: parent)
    let grandchild = item(studio, parent: child)
    let (after, other) = (item(studio), item(linux))

    let rows = nested([parent, child, grandchild, after, other], expanded: [parent, child]).rows

    #expect(
      SidebarRows.activeWorkspaceSections(rows).map { $0.map(\.id) } == [
        [parent.id, child.id, grandchild.id, after.id], [other.id],
      ])
  }

  @Test("A nested row reorders only among its siblings, each carrying its shown subtree")
  func reorderStaysAmongSiblings() {
    let parent = item(studio)
    let (first, second) = (item(studio, parent: parent), item(studio, parent: parent))
    let nephew = item(studio, parent: first)
    let root = item(studio)
    let all = [parent, first, nephew, second, root]
    let rows = nested(all, expanded: [parent, first]).rows

    #expect(SidebarRows.siblings(of: second.id, in: rows) == [first.id, second.id])
    #expect(SidebarRows.siblings(of: root.id, in: rows) == [parent.id, root.id])
    #expect(SidebarRows.subtree(of: first.id, in: rows) == [first.id, nephew.id])
    #expect(SidebarRows.subtree(of: parent.id, in: rows) == [parent.id, first.id, nephew.id, second.id])

    let moved = ListReorder.moving(
      second.id, to: 0, within: SidebarRows.siblings(of: second.id, in: rows), in: all.map(\.id))
    #expect(moved == [parent.id, second.id, nephew.id, first.id, root.id])
  }
}
