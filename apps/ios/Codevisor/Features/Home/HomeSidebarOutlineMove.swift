import CodevisorCore
import CodevisorUI
import Foundation

enum HomeSidebarOutlineMove {
  case bot(Bot, SidebarPlacement)
  case workspace(UUID, SidebarPlacement, siblings: [UUID], movesSection: Bool)
  case nested(HomeSidebarListEntry.Move)
  case section(UUID, toIndex: Int)

  typealias RowID = HomeSidebarOutline.RowID

  static func resolve(moving source: Int, to destination: Int, in items: [HomeSidebarOutline.Item]) -> Self? {
    guard items.indices.contains(source) else { return nil }

    let others = items.enumerated().filter { $0.offset != source }.map(\.element)
    let before = Array(others.prefix(destination > source ? destination - 1 : destination))
    switch items[source].row {
    case let .header(.section(section), _):
      return .section(section.id, toIndex: before.filter(\.isCustomHeader).count)
    case .header:
      return nil
    case let .bot(bot, _):
      return placement(of: bot.id, in: botRegion(items), before: before).map { .bot(bot.bot, $0) }
    case let .entry(entry, area):
      return entryMove(entry, area: area, source: source, destination: destination, items: items, before: before)
    }
  }

  private static func entryMove(
    _ entry: HomeSidebarListEntry, area: HomeSidebarOutline.Area, source: Int, destination: Int,
    items: [HomeSidebarOutline.Item], before: [HomeSidebarOutline.Item]
  ) -> Self? {
    guard entry.isTopLevelWorkspace else { return nestedMove(source: source, destination: destination, items: items) }
    if area != .pinned, before.last?.isPinned == true { return nil }

    let region = workspaceRegion(items, area: area)
    guard let placement = placement(of: entry.id, in: region, before: before) else { return nil }
    return .workspace(
      entry.id, placement, siblings: region.siblings(placing: entry.id, at: placement),
      movesSection: region.movesSections)
  }

  private static func nestedMove(source: Int, destination: Int, items: [HomeSidebarOutline.Item]) -> Self? {
    let entries = items.enumerated().compactMap { offset, item in item.entry.map { (offset, $0) } }
    guard let index = entries.firstIndex(where: { $0.0 == source }) else { return nil }

    let target = entries.filter { $0.0 < destination }.count
    return HomeSidebarListEntry.move(index, to: target, in: entries.map(\.1)).map(Self.nested)
  }

  private static func placement(
    of id: UUID, in region: SidebarDropRegion<RowID>, before: [HomeSidebarOutline.Item]
  ) -> SidebarPlacement? {
    region.placement(dropping: id, below: before.map(\.id))
  }

  private static func botRegion(_ items: [HomeSidebarOutline.Item]) -> SidebarDropRegion<RowID> {
    SidebarDropRegion(slots: items.compactMap(\.botSlot), movesSections: true)
  }

  private static func workspaceRegion(
    _ items: [HomeSidebarOutline.Item], area: HomeSidebarOutline.Area
  ) -> SidebarDropRegion<RowID> {
    guard area != .pinned else {
      return SidebarDropRegion(slots: items.compactMap { $0.workspaceSlot(in: [.pinned]) }, movesSections: false)
    }
    let headed = Set(items.compactMap(\.groupHeaderID))
    let lists = Set(items.compactMap(\.listGroup).filter { !headed.contains($0) || area == .list(group: $0) })
    let areas = Set(items.compactMap(\.sectionArea)).union(lists.map { .list(group: $0) })
    return SidebarDropRegion(
      slots: items.compactMap { $0.sectionHeaderSlot ?? $0.workspaceSlot(in: areas) }, movesSections: true,
      firstInsertion: 1)
  }
}

extension HomeSidebarOutline.Item {
  fileprivate var isCustomHeader: Bool {
    guard case .header(.section, _) = row else { return false }
    return true
  }

  fileprivate var isPinned: Bool {
    switch row {
    case .header(.pinned, _), .entry(_, .pinned): true
    default: false
    }
  }

  fileprivate var entry: HomeSidebarListEntry? {
    guard case let .entry(entry, _) = row else { return nil }
    return entry
  }

  fileprivate var groupHeaderID: String? {
    guard case let .header(.group(id, _), _) = row else { return nil }
    return id
  }

  fileprivate var listGroup: String? {
    guard case let .entry(_, .list(group)) = row else { return nil }
    return group
  }

  fileprivate var sectionArea: HomeSidebarOutline.Area? {
    guard case let .entry(_, area) = row, case .section = area else { return nil }
    return area
  }

  fileprivate var botSlot: SidebarDropSlot<HomeSidebarOutline.RowID>? {
    switch row {
    case let .bot(bot, section): .item(bot.id, row: id, section: section)
    case let .header(.section(section), _): .header(id, section: section.id)
    default: nil
    }
  }

  fileprivate var sectionHeaderSlot: SidebarDropSlot<HomeSidebarOutline.RowID>? {
    switch row {
    case let .header(.section(section), _): .header(id, section: section.id)
    case .header(.list, _): .header(id, section: nil)
    default: nil
    }
  }

  fileprivate func workspaceSlot(in areas: Set<HomeSidebarOutline.Area>) -> SidebarDropSlot<HomeSidebarOutline.RowID>? {
    guard case let .entry(entry, area) = row, entry.isTopLevelWorkspace, areas.contains(area) else { return nil }
    return .item(entry.id, row: id, section: area.section)
  }
}
