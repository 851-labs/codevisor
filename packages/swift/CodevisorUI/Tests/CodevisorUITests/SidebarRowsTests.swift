import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarRowsTests {
  private let studio = Project(id: UUID(), serverId: "studio", name: "codevisor")
  private let linux = Project(id: UUID(), serverId: "linux", name: "api")

  private func item(_ project: Project) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(id: UUID(), serverId: project.serverId, projectId: project.id, routingChatIds: [])
  }

  private func bot(children: [WorkspaceSidebarItem] = []) -> SidebarRows.Bot {
    SidebarRows.Bot(id: UUID(), serverId: "studio", workspaceId: UUID(), children: children)
  }

  private func groups(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping = .machine, pinned: [UUID] = []
  ) -> [SidebarWorkspaceGroup] {
    SidebarWorkspaceGroup.groups(
      items, grouping: grouping, pinnedIDs: pinned.map(\.uuidString), projects: [studio, linux],
      defaultServerId: "studio"
    ) { serverId in SidebarWorkspaceGroup.Heading(title: serverId, systemImage: "desktopcomputer") }
  }

  private struct Layout {
    let rows: [SidebarRow]

    var ids: [SidebarRowID] { rows.map(\.id) }

    func depth(of id: UUID) -> Int? {
      rows.first { $0.id == .workspace(id) }?.depth
    }
  }

  private func derive(_ state: SidebarRows.State) -> Layout {
    Layout(rows: SidebarRows.derive(state))
  }

  @Test("Every section renders in the sidebar's order: bots, pinned, the list header, groups, archived")
  func sectionOrder() {
    let child = item(studio)
    let helper = bot(children: [child])
    let (pinned, onStudio, onLinux) = (item(studio), item(studio), item(linux))
    let archived = [item(studio), item(linux)]

    let layout = derive(
      SidebarRows.State(
        bots: [helper], groups: groups([pinned, onStudio, onLinux], pinned: [pinned.id]), archived: archived,
        expansion: SidebarRows.Expansion(archived: true)))

    #expect(
      layout.ids == [
        .section(.bots), .bot(helper.id), .workspace(child.id),
        .section(.pinned), .workspace(pinned.id),
        .section(.list), .group("machine:studio"), .workspace(onStudio.id), .group("machine:linux"),
        .workspace(onLinux.id),
        .section(.archived), .workspace(archived[0].id), .workspace(archived[1].id),
      ])
    #expect(layout.rows.map(\.depth) == [0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0])
    #expect(
      layout.rows.map(\.section) == [.bots, .bots, .bots, .pinned, .pinned, .list, .list, .list, .list, .list]
        + [.archived, .archived, .archived])
  }

  @Test("A workspace keeps one row id whether it's in a group, Pinned, under a bot, or in Archived")
  func workspaceIdentitySurvivesEveryMove() {
    let moving = item(studio)
    let other = item(studio)
    let placements: [SidebarRows.State] = [
      SidebarRows.State(groups: groups([moving, other])),
      SidebarRows.State(groups: groups([moving, other], pinned: [moving.id])),
      SidebarRows.State(bots: [bot(children: [moving])], groups: groups([other])),
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

  @Test("Bots: collapsed sections keep the selected bot or child, and a bot's own toggle folds its children")
  func botsKeepTheirSelection() {
    let (first, second) = (item(studio), item(studio))
    let busy = bot(children: [first, second])
    let idle = bot()
    let list = groups([])
    func layout(
      _ expansion: SidebarRows.Expansion, workspace: UUID? = nil, bot selectedBot: UUID? = nil
    ) -> Layout {
      derive(
        SidebarRows.State(
          bots: [busy, idle], groups: list, expansion: expansion, selectedWorkspaceID: workspace,
          selectedBotID: selectedBot))
    }

    #expect(
      layout(SidebarRows.Expansion(bots: false), workspace: second.id).ids == [
        .section(.bots), .bot(busy.id), .workspace(second.id), .section(.list),
      ])
    #expect(
      layout(SidebarRows.Expansion(bots: false), bot: idle.id).ids == [
        .section(.bots), .bot(idle.id), .section(.list),
      ])
    #expect(
      layout(SidebarRows.Expansion(bots: false), workspace: idle.workspaceId).ids == [
        .section(.bots), .bot(idle.id), .section(.list),
      ])

    let folded = layout(SidebarRows.Expansion(collapsedGroupIDs: [busy.groupID]), workspace: first.id)
    #expect(
      folded.ids == [
        .section(.bots), .bot(busy.id), .workspace(first.id), .bot(idle.id), .section(.list),
      ])
    #expect(folded.rows[1].kind == .bot(busy, isExpanded: false))
    #expect(folded.rows[3].kind == .bot(idle, isExpanded: nil))
    #expect(layout(SidebarRows.Expansion(bots: false), workspace: first.id).rows[1].kind == .bot(busy, isExpanded: nil))
  }

  @Test("The Bots section shows only when there are bots or one can be created, with New bot while it's empty")
  func botsSectionVisibility() {
    let list = groups([])

    #expect(derive(SidebarRows.State(bots: nil, canCreateBots: true, groups: list)).ids == [.section(.list)])
    #expect(derive(SidebarRows.State(bots: [], canCreateBots: false, groups: list)).ids == [.section(.list)])
    #expect(
      derive(SidebarRows.State(bots: [], canCreateBots: true, groups: list)).ids == [
        .section(.bots), .newBot, .section(.list),
      ])
    #expect(
      derive(
        SidebarRows.State(
          bots: [], canCreateBots: true, groups: list, expansion: SidebarRows.Expansion(bots: false))
      ).ids == [.section(.bots), .section(.list)])
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
    let child = item(studio)
    let helper = bot(children: [child])
    let listed = [item(studio), item(linux), item(studio), item(linux)]
    let archived = [item(studio), item(linux), item(studio)]
    let selections: [UUID?] = [nil, child.id, listed[0].id, listed[1].id, archived[1].id, helper.workspaceId]

    for grouping in SidebarGrouping.allCases {
      for mask in 0..<32 {
        for selected in selections {
          let expansion = SidebarRows.Expansion(
            bots: mask & 1 != 0, pinned: mask & 2 != 0, list: mask & 4 != 0, archived: mask & 8 != 0,
            collapsedGroupIDs: mask & 16 != 0 ? ["machine:studio", "machine:linux", helper.groupID] : [])
          let ids = derive(
            SidebarRows.State(
              bots: [helper], groups: groups(listed, grouping, pinned: [listed[0].id]), archived: archived,
              archivedVisibleCount: 2, expansion: expansion, selectedWorkspaceID: selected)
          ).ids
          #expect(Set(ids).count == ids.count)
          if let selected, selected != helper.workspaceId {
            #expect(ids.contains(.workspace(selected)))
          }
        }
      }
    }
  }

  @Test("Archive selection sections are each bot's children, Pinned, then each group, without Archived")
  func activeWorkspaceSections() {
    let (child, pinned, first, second, other) = (item(studio), item(studio), item(studio), item(studio), item(linux))
    let rows = SidebarRows.derive(
      SidebarRows.State(
        bots: [bot(children: [child]), bot()], groups: groups([pinned, first, second, other], pinned: [pinned.id]),
        archived: [item(studio)], expansion: SidebarRows.Expansion(archived: true)))

    #expect(
      SidebarRows.activeWorkspaceSections(rows).map { $0.map(\.id) } == [
        [child.id], [pinned.id], [first.id, second.id], [other.id],
      ])
  }
}
