import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  func workspaceRowList(_ rows: [SidebarRow]) -> some View {
    let routed = routedWorkspace
    let actions = rowActions
    let bots = Dictionary(botEntries.map { ($0.bot.id, $0.bot) }, uniquingKeysWith: { first, _ in first })
    return SidebarRowList(rows: rows, id: \.placedID, animation: Motion.listReflow(reduceMotion: reduceMotion)) { row in
      workspaceRegionRow(row, routed: routed, bots: bots, actions: actions)
    }
  }

  @ViewBuilder
  private func workspaceRegionRow(
    _ row: SidebarRow, routed: (serverId: String, id: UUID)?, bots: [UUID: Bot],
    actions: SidebarWorkspaceSection.Actions
  ) -> some View {
    switch row.kind {
    case let .section(.bots, isExpanded):
      SidebarSectionHeader(
        title: "Bots",
        isExpanded: isExpanded,
        onToggle: { botsExpanded.toggle() },
        add: SidebarSectionHeader.Add(help: "New Bot") { botEditor = .create }
      )
    case let .bot(entry, isExpanded):
      if let bot = bots[entry.id] {
        botRow(bot, isExpanded: isExpanded)
      }
    case .newBot:
      SidebarActionRow(
        title: "New bot", systemImage: "plus", isSelected: false, isHoverEnabled: !isReordering,
        titleStyle: .secondary
      ) {
        botEditor = .create
      }
    case let .section(.pinned, isExpanded):
      SidebarSectionHeader(title: "Pinned", isExpanded: isExpanded) { pinnedExpanded.toggle() }
    case let .section(.list, isExpanded):
      SidebarSectionHeader(title: grouping.listTitle, isExpanded: isExpanded) { listExpanded.toggle() }
    case let .section(.archived, isExpanded):
      SidebarSectionHeader(title: "Archived", isExpanded: isExpanded) { toggleArchived() }
    case let .workspace(item, .archived):
      if let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace {
        archivedRow(workspace, item: item)
          .id(workspace.id)
      }
    case .showMoreArchived:
      SidebarActionRow(
        title: "Show More", systemImage: "ellipsis", isSelected: false, isHoverEnabled: !isReordering,
        titleStyle: .secondary
      ) {
        archivedVisibleCount += sidebarArchivedPageSize
      }
    case let .group(id, heading, isExpanded):
      groupHeadingRow(id: id, heading: heading, isExpanded: isExpanded)
    case let .workspace(item, placement):
      SidebarWorkspaceSection(
        item: item, store: store, grouping: grouping, rowDetails: rowDetails,
        isSelected: routed?.serverId == item.serverId && routed?.id == item.id,
        isPinned: placement == .pinned, isReordering: isReordering, actions: actions
      )
      .equatable()
      .opacity(draggingID == item.id ? 0.4 : 1)
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .named(Self.reorderSpace))
      } action: { frame in
        recordWorkspaceFrame(frame, for: item.id)
      }
      .onDisappear { forgetWorkspaceGeometry(for: item.id) }
      .simultaneousGesture(reorderGesture(for: item.id))
      .geometryGroup()
      .padding(.leading, Self.groupIndent * CGFloat(row.depth))
      .id(item.id)
    }
  }

  private func groupHeadingRow(id: String, heading: SidebarWorkspaceGroup.Heading, isExpanded: Bool) -> some View {
    SidebarGroupRow(
      title: heading.title,
      systemImage: heading.systemImage,
      isExpanded: isExpanded,
      isReordering: isReordering,
      onToggle: {
        guard allowsGroupToggle else { return }
        toggleGroup(id)
      },
      onNewChat: heading.newChatTarget.map { target in { selection = .newChat(target) } }
    )
    .opacity(groupDrag?.groupID == id ? 0.4 : 1)
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(Self.reorderSpace))
    } action: { frame in
      dragGeometry.headings[id] = frame
    }
    .onDisappear { dragGeometry.headings[id] = nil }
    .simultaneousGesture(
      groupReorderGesture(for: id, heading: heading), including: reordersGroups ? .all : .subviews)
  }
}

private struct SidebarPlacedRowID: Hashable {
  let id: SidebarRowID
  let section: SidebarSection
}

extension SidebarRow {
  fileprivate var placedID: SidebarPlacedRowID {
    SidebarPlacedRowID(id: id, section: section)
  }
}
