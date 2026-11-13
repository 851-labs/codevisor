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
      id: id, serverId: project.serverId, projectId: project.id, routingChatIds: [],
      parent: parent.map { WorkspaceParentLink(workspaceId: $0, linkedAt: .distantPast, isQuiet: false) })
  }

  private func groups(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping = .machine, pinned: [UUID] = [],
    sections: [CustomSection] = [], membership: [UUID: UUID] = [:]
  ) -> [SidebarWorkspaceGroup] {
    SidebarWorkspaceGroup.groups(
      items, grouping: grouping, pinnedIDs: pinned.map(\.uuidString), projects: [studio, linux, site],
      defaultServerId: "studio", sections: sections, membership: membership
    ) { serverId in
      SidebarMachineGroup(
        key: serverId, orderKey: serverId,
        heading: SidebarWorkspaceGroup.Heading(title: serverId, icon: .system("desktopcomputer")))
    }
  }

  private func nested(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping = .machine, pinned: [UUID] = [],
    archived: [WorkspaceSidebarItem] = [], archivedVisibleCount: Int = sidebarArchivedPageSize,
    tabs: [UUID: [UUID]] = [:],
    expansion: SidebarRows.Expansion = SidebarRows.Expansion(), selecting selected: UUID? = nil,
    selectingTab selectedTab: UUID? = nil
  ) -> Layout {
    let tree = SidebarWorkspaceTree(items, pinnedIDs: pinned.map(\.uuidString))
    return derive(
      SidebarRows.State(
        groups: groups(tree.roots, grouping, pinned: pinned), children: tree.children, tabs: tabs,
        archived: archived,
        archivedVisibleCount: archivedVisibleCount, expansion: expansion, selectedWorkspaceID: selected,
        selectedTabID: selectedTab))
  }

  private struct Layout {
    let rows: [SidebarRow]

    var ids: [SidebarRowID] { rows.map(\.id) }

    func depth(of id: UUID) -> Int? {
      row(id)?.depth
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

  @Test(
    "Custom sections sit between Pinned and the list in order; Pinned wins over a section, and a workspace whose section is gone stays in its group"
  )
  func customSectionLayout() {
    let (pinned, filed, nested, orphaned, loose) = (item(studio), item(linux), item(studio), item(studio), item(linux))
    let child = item(studio, parent: filed)
    let (work, home) = (
      CustomSection(id: UUID(), name: "Work", position: "4"), CustomSection(id: UUID(), name: "Home", position: "8")
    )
    let membership = [pinned.id: work.id, filed.id: work.id, nested.id: work.id, orphaned.id: UUID()]
    let tree = SidebarWorkspaceTree([pinned, filed, child, nested, orphaned, loose], pinnedIDs: [pinned.id.uuidString])

    let layout = derive(
      SidebarRows.State(
        groups: groups(tree.roots, pinned: [pinned.id], sections: [work, home], membership: membership),
        children: tree.children))

    #expect(
      layout.ids == [
        .section(.pinned), .workspace(pinned.id),
        .section(.custom(work.id)), .workspace(filed.id), .workspace(child.id), .workspace(nested.id),
        .section(.custom(home.id)),
        .section(.list), .group("machine:studio"), .workspace(orphaned.id), .group("machine:linux"),
        .workspace(loose.id),
      ])
    #expect(layout.depth(of: filed.id) == 0)
    #expect(layout.depth(of: child.id) == 1)
    #expect(SidebarRows.siblings(of: nested.id, in: layout.rows) == [filed.id, nested.id])
  }

  @Test("A collapsed custom section keeps only the selected workspace")
  func collapsedCustomSectionKeepsSelection() {
    let (selected, hidden) = (item(studio), item(studio))
    let work = CustomSection(id: UUID(), name: "Work", position: "8")
    let all = groups([selected, hidden], sections: [work], membership: [selected.id: work.id, hidden.id: work.id])

    let layout = derive(
      SidebarRows.State(
        groups: all,
        expansion: SidebarRows.Expansion(collapsedGroupIDs: [SidebarWorkspaceGroup.customSectionID(work.id)]),
        selectedWorkspaceID: selected.id))

    #expect(layout.ids == [.section(.custom(work.id)), .workspace(selected.id), .section(.list)])
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
      ids(visibleCount: 3) == [.section(.archived)] + archived.prefix(3).map { .workspace($0.id) }
        + [.showMoreArchived])
    #expect(ids(visibleCount: 5) == [.section(.archived)] + archived.map { .workspace($0.id) })
    #expect(ids(visibleCount: 3, expanded: false) == [.section(.archived)])
  }

  @Test("With no active workspaces, no Pinned, section or list headers show: only Archived, or nothing")
  func noActiveWorkspacesLeavesNoEmptyHeaders() {
    let section = CustomSection(id: UUID(), name: "Later", position: "4")
    let archived = [item(studio)]
    func ids(_ grouping: SidebarGrouping, archived: [WorkspaceSidebarItem]) -> [SidebarRowID] {
      derive(SidebarRows.State(groups: groups([], grouping, sections: [section]), archived: archived)).ids
    }

    for grouping in SidebarGrouping.allCases {
      #expect(ids(grouping, archived: archived) == [.section(.archived)])
      #expect(ids(grouping, archived: []).isEmpty)
    }
  }

  @Test("Row ids stay unique across every combination of grouping, expansion and selection")
  func rowIdsAreUnique() {
    let parent = item(studio)
    let child = item(linux, parent: parent)
    let listed = [parent, item(linux), child, item(studio, parent: child)]
    let archived = [item(studio), item(linux, parent: parent), item(studio)]
    let selections: [UUID?] = [nil, listed[0].id, listed[1].id, listed[3].id, archived[1].id]

    for grouping in SidebarGrouping.allCases {
      for mask in 0..<16 {
        for selected in selections {
          let expansion = SidebarRows.Expansion(
            pinned: mask & 1 != 0, list: mask & 2 != 0, archived: mask & 4 != 0,
            collapsedGroupIDs: mask & 8 != 0 ? ["machine:studio", "machine:linux"] : [])
          let ids = nested(
            listed, grouping, pinned: [listed[0].id], archived: archived, archivedVisibleCount: 2,
            expansion: expansion, selecting: selected
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

  @Test("Forked workspaces nest under their parent at any depth, always expanded")
  func nestingIsRecursiveAndAlwaysExpanded() {
    let parent = item(studio)
    let (child, sibling) = (item(studio, parent: parent), item(studio, parent: parent))
    let grandchild = item(studio, parent: child)
    let next = item(studio)
    let all = [parent, child, grandchild, sibling, next]

    let expanded = nested(all)
    #expect(
      Array(expanded.ids.dropFirst(2))
        == [parent, child, grandchild, sibling, next].map { .workspace($0.id) })
    #expect([parent, child, grandchild, sibling, next].map { expanded.depth(of: $0.id) } == [1, 2, 3, 2, 1])
    #expect(expanded.rows.compactMap(\.parentID) == [parent.id, child.id, parent.id])
  }

  @Test("A child nests under its parent even when it belongs to another group, and its own group drops out")
  func childrenNestAcrossGroups() {
    let parent = item(studio)
    let child = item(site, parent: parent)

    let layout = nested([parent, child], .project)

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

  @Test("A nested workspace's root is its top-level ancestor, whose row places it in the sidebar")
  func rootIsTopLevelAncestor() {
    let parent = item(studio)
    let child = item(site, parent: parent)
    let grandchild = item(linux, parent: child)
    let (firstID, secondID) = (UUID(), UUID())
    let cyclic = item(studio, id: firstID, parent: secondID)
    let underCycle = item(studio, parent: cyclic)

    let tree = SidebarWorkspaceTree(
      [parent, child, grandchild, cyclic, item(studio, id: secondID, parent: firstID), underCycle], pinnedIDs: [])

    #expect([parent, child, grandchild].map { tree.root(of: $0.id) } == [parent.id, parent.id, parent.id])
    #expect(tree.root(of: underCycle.id) == cyclic.id)
  }

  @Test("A collapsed group or section keeps only the selected descendant, one step under the nearest shown row")
  func collapsedGroupKeepsTheSelectedDescendant() {
    let parent = item(studio)
    let child = item(studio, parent: parent)
    let grandchild = item(studio, parent: child)
    let all = [parent, child, grandchild]

    #expect(nested(all, selecting: grandchild.id).depth(of: grandchild.id) == 3)

    let groupCollapsed = nested(
      all, expansion: SidebarRows.Expansion(collapsedGroupIDs: ["machine:studio"]), selecting: grandchild.id)
    #expect(groupCollapsed.ids == [.section(.list), .group("machine:studio"), .workspace(grandchild.id)])
    #expect(groupCollapsed.depth(of: grandchild.id) == 1)

    let listCollapsed = nested(all, expansion: SidebarRows.Expansion(list: false), selecting: grandchild.id)
    #expect(listCollapsed.depth(of: grandchild.id) == 0)
  }

  @Test("Pinning a child pins just that one; a pinned parent keeps its unpinned children")
  func pinnedChildrenAndParents() {
    let parent = item(studio)
    let (pinnedChild, child) = (item(studio, parent: parent), item(studio, parent: parent))

    let childPinned = nested([parent, pinnedChild, child], pinned: [pinnedChild.id])
    #expect(
      childPinned.ids == [
        .section(.pinned), .workspace(pinnedChild.id), .section(.list), .group("machine:studio"),
        .workspace(parent.id), .workspace(child.id),
      ])

    let parentPinned = nested([parent, pinnedChild, child], pinned: [parent.id])
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
      [parent], archived: [archivedChild], expansion: SidebarRows.Expansion(archived: true))
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

    let rows = nested([parent, child, grandchild, after, other]).rows

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
    let rows = nested(all).rows

    #expect(SidebarRows.siblings(of: second.id, in: rows) == [first.id, second.id])
    #expect(SidebarRows.siblings(of: root.id, in: rows) == [parent.id, root.id])
    #expect(SidebarRows.subtree(of: first.id, in: rows) == [first.id, nephew.id])
    #expect(SidebarRows.subtree(of: parent.id, in: rows) == [parent.id, first.id, nephew.id, second.id])

    let moved = ListReorder.placing(
      second.id, at: 0, among: SidebarRows.siblings(of: second.id, in: rows), in: all.map(\.id))
    #expect(moved == [parent.id, second.id, first.id, nephew.id, root.id])
  }

  @Test("A workspace's tabs nest above its children; in a collapsed group only the selected tab stays")
  func tabsNestAboveChildren() {
    let parent = item(studio)
    let child = item(studio, parent: parent)
    let (alone, after) = (item(studio), item(studio))
    let (terminal, browser, aloneTab) = (UUID(), UUID(), UUID())
    let all = [parent, child, alone, after]
    let tabs = [parent.id: [terminal, browser], alone.id: [aloneTab]]

    let expanded = nested(all, tabs: tabs)
    #expect(
      expanded.ids.dropFirst(2) == [
        .workspace(parent.id), .tab(terminal), .tab(browser), .workspace(child.id), .workspace(alone.id),
        .tab(aloneTab), .workspace(after.id),
      ])
    #expect(expanded.rows.first { $0.id == .tab(terminal) }?.depth == 2)
    #expect(SidebarRows.tabs(of: parent.id, in: expanded.rows) == [terminal, browser])
    #expect(
      SidebarRows.activeWorkspaceSections(expanded.rows).map { $0.map(\.id) } == [all.map(\.id)])

    let keepsSelected = nested(
      all, tabs: tabs, expansion: SidebarRows.Expansion(collapsedGroupIDs: ["machine:studio"]), selecting: parent.id,
      selectingTab: browser)
    #expect(keepsSelected.ids.dropFirst(2) == [.workspace(parent.id), .tab(browser)])
  }
}
