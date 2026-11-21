import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  func workspaceRowList(_ rows: [SidebarRow]) -> some View {
    let actions = rowActions
    let namingMachine = Self.placementsNamingMachine(in: rows)
    let sections = environment.workspaceSections.sections
    let membership = environment.workspaceSections.membership
    let statuses = rowStatuses
    let details = rowDetails
    return SidebarRowList(rows: rows, id: \.placedID, animation: Motion.listReflow(reduceMotion: reduceMotion)) { row in
      workspaceRegionRow(
        row, actions: actions, namingMachine: namingMachine, sections: sections,
        membership: membership, statuses: statuses, rowDetails: details)
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
    _ row: SidebarRow,
    actions: SidebarWorkspaceSection.Actions, namingMachine: Set<SidebarRow.Placement>, sections: [CustomSection],
    membership: [UUID: UUID], statuses: SidebarRowStatuses, rowDetails: [SidebarRowDetail]
  ) -> some View {
    switch row.kind {
    case let .section(.pinned, isExpanded):
      SidebarSectionHeader(title: "Pinned", isExpanded: isExpanded) { pinnedExpanded.toggle() }
    case let .section(.list, isExpanded):
      SidebarSectionHeader(title: grouping.listTitle, isExpanded: isExpanded) { listExpanded.toggle() }
        .modifier(SidebarReorderHighlight(reorder: reorder, section: nil))
        .modifier(SidebarReorderFrame(reorder: reorder, row: row.id))
    case let .section(.custom(id), isExpanded):
      if let section = sections.first(where: { $0.id == id }) {
        customSectionHeader(section, isExpanded: isExpanded)
      }
    case let .section(.archived, isExpanded):
      SidebarSectionHeader(title: "Archived", isExpanded: isExpanded) { toggleArchived() }
    case let .workspace(item, .archived):
      selectableArchivedRow(row, item: item)
    case let .tab(tabID, workspaceID, placement):
      SidebarSelectedRow(id: row.id, selection: selectionModel.rows) { isSelected in
        reorderableTabRow(
          tabID, of: workspaceID, reorders: placement != .archived, depth: row.depth, isSelected: isSelected)
      }
    case .showMoreArchived:
      showMoreArchivedRow
    case let .group(id, heading, isExpanded):
      groupHeadingRow(id: id, heading: heading, isExpanded: isExpanded)
    case let .workspace(item, placement):
      SidebarWorkspaceSection(
        item: item, store: store, grouping: grouping, rowDetails: rowDetails,
        status: statuses.status(of: item.id),
        selection: selectionModel.rows,
        isPinned: placement == .pinned, headingNamesMachine: namingMachine.contains(placement),
        isReordering: isReordering,
        sectionPlacement: WorkspaceSectionPlacement(row, membership: membership),
        sections: sections, actions: actions
      )
      .equatable()
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: SidebarReorderSpace.coordinateSpace)
      } action: { frame in
        recordWorkspaceFrame(frame, for: item.id, in: placement)
      }
      .onDisappear { forgetWorkspaceGeometry(for: item.id, in: placement) }
      .modifier(workspaceReorder(item.id))
      .geometryGroup()
      .padding(.leading, Self.groupIndent * CGFloat(row.depth))
      .id(item.id)
    }
  }

  @ViewBuilder
  private func selectableArchivedRow(_ row: SidebarRow, item: WorkspaceSidebarItem) -> some View {
    if let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace {
      SidebarSelectedRow(id: row.id, selection: selectionModel.rows) { isSelected in
        archivedRow(workspace, item: item, isSelected: isSelected)
      }
      .id(workspace.id)
    }
  }

  private func groupHeadingRow(id: String, heading: SidebarWorkspaceGroup.Heading, isExpanded: Bool) -> some View {
    SidebarGroupRow(
      title: heading.title,
      icon: heading.icon,
      isExpanded: isExpanded,
      isReordering: isReordering,
      onToggle: {
        guard reorder.allowsToggle else { return }
        toggleGroup(id)
      },
      onNewChat: heading.newChatTarget.map { target in { selection = .newChat(target) } }
    )
    .modifier(headerReorder(.group(id), isEnabled: reordersGroups))
  }

  private func customSectionHeader(_ section: CustomSection, isExpanded: Bool) -> some View {
    let id = SidebarWorkspaceGroup.customSectionID(section.id)
    return CustomSectionHeader(
      section: section, isExpanded: isExpanded,
      onToggle: {
        guard reorder.allowsToggle else { return }
        toggleGroup(id)
      },
      actions: CustomSectionActions(
        sections: environment.workspaceSections.sections, section: section,
        rename: { sectionPrompt = .rename($0) }, delete: deleteSection,
        move: { environment.workspaceSections.moveSection($0, toIndex: $1) })
    )
    .modifier(SidebarReorderHighlight(reorder: reorder, section: section.id))
    .modifier(headerReorder(.section(.custom(section.id))))
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
