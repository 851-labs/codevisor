import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  func workspaceRowList(_ rows: [SidebarRow]) -> some View {
    let selected = selectedRowID(in: rows)
    let actions = rowActions
    let namingMachine = Self.placementsNamingMachine(in: rows)
    let sections = environment.workspaceSections.sections
    let membership = environment.workspaceSections.membership
    let statuses = rowStatuses
    return SidebarRowList(rows: rows, id: \.placedID, animation: Motion.listReflow(reduceMotion: reduceMotion)) { row in
      workspaceRegionRow(
        row, selected: selected, actions: actions, namingMachine: namingMachine, sections: sections,
        membership: membership, statuses: statuses)
    }
  }

  private var rowStatuses: SidebarRowStatuses {
    SidebarRowStatusSource(environment: environment, store: store).statuses
  }

  private static func placementsNamingMachine(in rows: [SidebarRow]) -> Set<SidebarRow.Placement> {
    Set(
      rows.compactMap { row in
        guard case let .group(id, heading, _) = row.kind, heading.namesMachine else { return nil }
        return .group(id)
      })
  }

  @ViewBuilder
  private func workspaceRegionRow(
    _ row: SidebarRow, selected: SidebarRowID?,
    actions: SidebarWorkspaceSection.Actions, namingMachine: Set<SidebarRow.Placement>, sections: [CustomSection],
    membership: [UUID: UUID], statuses: SidebarRowStatuses
  ) -> some View {
    switch row.kind {
    case let .section(.pinned, isExpanded):
      SidebarSectionHeader(title: "Pinned", isExpanded: isExpanded) { pinnedExpanded.toggle() }
    case let .section(.list, isExpanded):
      SidebarSectionHeader(title: grouping.listTitle, isExpanded: isExpanded) { listExpanded.toggle() }
        .background(SidebarDropHighlight(isActive: drag?.sectionTarget == .unsectioned))
        .modifier(
          SidebarHeadingFrameRecorder(id: WorkspaceSectionPlacement.unsectionedHeadingID, geometry: dragGeometry))
    case let .section(.custom(id), isExpanded):
      if let section = sections.first(where: { $0.id == id }) {
        customSectionHeader(section, isExpanded: isExpanded)
      }
    case let .section(.archived, isExpanded):
      SidebarSectionHeader(title: "Archived", isExpanded: isExpanded) { toggleArchived() }
    case let .workspace(item, .archived):
      if let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace {
        archivedRow(workspace, item: item, isSelected: selected == row.id)
          .id(workspace.id)
      }
    case let .tab(tabID, workspaceID, placement):
      reorderableTabRow(
        tabID, of: workspaceID, reorders: placement != .archived, depth: row.depth, isSelected: selected == row.id)
    case .showMoreArchived:
      showMoreArchivedRow
    case let .group(id, heading, isExpanded):
      groupHeadingRow(id: id, heading: heading, isExpanded: isExpanded)
    case let .workspace(item, placement):
      SidebarWorkspaceSection(
        item: item, store: store, grouping: grouping, rowDetails: rowDetails,
        status: statuses.status(of: item.id),
        isSelected: selected == row.id,
        isPinned: placement == .pinned, headingNamesMachine: namingMachine.contains(placement),
        isReordering: isReordering,
        sectionPlacement: WorkspaceSectionPlacement(row, membership: membership),
        sections: sections, actions: actions
      )
      .equatable()
      .opacity(draggingID == item.id ? 0.4 : 1)
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .named(Self.reorderSpace))
      } action: { frame in
        recordWorkspaceFrame(frame, for: item.id, in: placement)
      }
      .onDisappear { forgetWorkspaceGeometry(for: item.id, in: placement) }
      .simultaneousGesture(reorderGesture(for: item.id))
      .geometryGroup()
      .padding(.leading, Self.groupIndent * CGFloat(row.depth))
      .id(item.id)
    }
  }

  private func groupHeadingRow(id: String, heading: SidebarWorkspaceGroup.Heading, isExpanded: Bool) -> some View {
    SidebarGroupRow(
      title: heading.title,
      icon: heading.icon,
      isExpanded: isExpanded,
      isReordering: isReordering,
      onToggle: {
        guard allowsGroupToggle else { return }
        toggleGroup(id)
      },
      onNewChat: heading.newChatTarget.map { target in { selection = .newChat(target) } }
    )
    .opacity(groupDrag?.groupID == id ? 0.4 : 1)
    .modifier(SidebarHeadingFrameRecorder(id: id, geometry: dragGeometry))
    .simultaneousGesture(
      groupReorderGesture(for: id, title: heading.title, icon: heading.icon),
      including: reordersGroups ? .all : .subviews)
  }

  private func customSectionHeader(_ section: CustomSection, isExpanded: Bool) -> some View {
    let id = SidebarWorkspaceGroup.customSectionID(section.id)
    return CustomSectionHeader(
      section: section, isExpanded: isExpanded, isDropTarget: drag?.sectionTarget == .section(section.id),
      onToggle: {
        guard allowsGroupToggle else { return }
        toggleGroup(id)
      },
      onRename: { sectionPrompt = .rename(section) },
      onDelete: { deleteSection(section) }
    )
    .opacity(groupDrag?.groupID == id ? 0.4 : 1)
    .modifier(SidebarHeadingFrameRecorder(id: id, geometry: dragGeometry))
    .simultaneousGesture(groupReorderGesture(for: id, title: section.name, icon: nil))
  }

  private func deleteSection(_ section: CustomSection) {
    environment.workspaceSections.delete(section.id)
    collapsedGroupIDs.removeAll { $0 == SidebarWorkspaceGroup.customSectionID(section.id) }
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
