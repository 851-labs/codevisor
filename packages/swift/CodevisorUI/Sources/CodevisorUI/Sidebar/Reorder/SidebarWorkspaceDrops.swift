import Foundation

public enum SidebarWorkspaceDrops {
  public static func region(dragging id: UUID, in rows: [SidebarRow]) -> SidebarDropRegion<SidebarRowID>? {
    guard let row = rows.first(where: { $0.id == .workspace(id) }), case let .workspace(_, placement) = row.kind
    else { return nil }

    if let parent = row.parentID {
      return SidebarDropRegion(slots: items(in: rows) { $0.parentID == parent }, movesSections: false)
    }
    switch placement {
    case .archived: return nil
    case .pinned: return SidebarDropRegion(slots: items(in: rows) { isTopLevel($0, in: .pinned) }, movesSections: false)
    case .custom, .group:
      return SidebarDropRegion(slots: sectioned(rows, dragging: placement), movesSections: true, firstInsertion: 1)
    }
  }

  public static func blocks(dragging header: SidebarRowID, in rows: [SidebarRow]) -> SidebarDropBlocks<SidebarRowID>? {
    switch header {
    case .section(.custom): SidebarDropBlocks(rows.compactMap { customBlock($0, in: rows) })
    case .group: SidebarDropBlocks(rows.compactMap { groupBlock($0, in: rows) })
    default: nil
    }
  }

  private static func sectioned(
    _ rows: [SidebarRow], dragging placement: SidebarRow.Placement
  ) -> [SidebarDropSlot<SidebarRowID>] {
    let headed = Set(rows.compactMap(\.groupID))
    return rows.compactMap { row in
      switch row.kind {
      case let .section(.custom(id), _): .header(row.id, section: id)
      case .section(.list, _): .header(row.id, section: nil)
      case let .workspace(item, .custom(id)) where row.parentID == nil: slot(for: item.id, section: id, in: rows)
      case let .workspace(item, .group(group))
      where row.parentID == nil && (!headed.contains(group) || placement == .group(group)):
        slot(for: item.id, section: nil, in: rows)
      default: nil
      }
    }
  }

  private static func items(
    in rows: [SidebarRow], where included: (SidebarRow) -> Bool
  ) -> [SidebarDropSlot<SidebarRowID>] {
    rows.compactMap { row in
      guard case let .workspace(item, _) = row.kind, included(row) else { return nil }
      return slot(for: item.id, section: nil, in: rows)
    }
  }

  private static func slot(for id: UUID, section: UUID?, in rows: [SidebarRow]) -> SidebarDropSlot<SidebarRowID> {
    let members = SidebarRows.subtree(of: id, in: rows)
    let tabs = members.flatMap { SidebarRows.tabs(of: $0, in: rows) }.map(SidebarRowID.tab)
    return .item(id, row: .workspace(id), section: section, rows: members.map(SidebarRowID.workspace) + tabs)
  }

  private static func isTopLevel(_ row: SidebarRow, in placement: SidebarRow.Placement) -> Bool {
    guard row.parentID == nil, case let .workspace(_, rowPlacement) = row.kind else { return false }
    return rowPlacement == placement
  }

  private static func customBlock(_ row: SidebarRow, in rows: [SidebarRow]) -> SidebarDropBlock<SidebarRowID>? {
    guard case let .section(.custom(id), _) = row.kind else { return nil }
    return SidebarDropBlock(header: row.id, rows: members(placed: .custom(id), in: rows))
  }

  private static func groupBlock(_ row: SidebarRow, in rows: [SidebarRow]) -> SidebarDropBlock<SidebarRowID>? {
    guard let group = row.groupID else { return nil }
    return SidebarDropBlock(header: row.id, rows: members(placed: .group(group), in: rows))
  }

  private static func members(placed placement: SidebarRow.Placement, in rows: [SidebarRow]) -> [SidebarRowID] {
    rows.filter { $0.placement == placement }.map(\.id)
  }
}
