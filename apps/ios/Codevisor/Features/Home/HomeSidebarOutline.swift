import CodevisorCore
import CodevisorUI
import Foundation

struct HomeSidebarOutline {
  enum RowID: Hashable {
    case header(String)
    case item(UUID)
  }

  enum Header {
    case pinned
    case section(CustomSection)
    case list(String)
    case group(String, SidebarWorkspaceGroup.Heading)

    var id: String {
      switch self {
      case .pinned: SidebarWorkspaceGroup.pinnedID
      case let .section(section): SidebarWorkspaceGroup.customSectionID(section.id)
      case .list: "list"
      case let .group(id, _): id
      }
    }
  }

  enum Area: Hashable {
    case pinned
    case section(UUID)
    case list(group: String)

    var section: UUID? {
      guard case let .section(id) = self else { return nil }
      return id
    }
  }

  enum Row {
    case header(Header, isExpanded: Bool)
    case bot(HomeSidebarBot, section: UUID?)
    case entry(HomeSidebarListEntry, area: Area)
  }

  struct Item: Identifiable {
    let row: Row

    var isHeader: Bool {
      guard case .header = row else { return false }
      return true
    }

    var isMovable: Bool {
      switch row {
      case .header(.section, _), .bot, .entry: true
      case .header: false
      }
    }

    var id: RowID {
      switch row {
      case let .header(header, _): .header(header.id)
      case let .bot(bot, _): .item(bot.id)
      case let .entry(entry, _): .item(entry.id)
      }
    }
  }

  struct Expansion {
    var pinned = true
    var list = true
    var collapsedIDs: Set<String> = []

    func isExpanded(_ id: String) -> Bool { !collapsedIDs.contains(id) }
  }

  var items: [Item] = []

  func cardEdges(at index: Int) -> HomeSidebarCardEdges {
    HomeSidebarCardEdges(
      top: !items.indices.contains(index - 1) || items[index - 1].isHeader,
      bottom: !items.indices.contains(index + 1) || items[index + 1].isHeader)
  }

  static func bots(_ content: HomeSidebarContent, expansion: Expansion) -> Self {
    var outline = Self()
    outline.append(content.unsectionedBots.map { .bot($0, section: nil) })
    for group in content.botSectionGroups {
      let isExpanded = expansion.isExpanded(group.collapseID)
      outline.append([.header(.section(group.section), isExpanded: isExpanded)])
      if isExpanded { outline.append(group.bots.map { .bot($0, section: group.section.id) }) }
    }
    return outline
  }

  static func code(_ content: HomeSidebarContent, expansion: Expansion) -> Self {
    var outline = Self()
    if !content.pinned.isEmpty {
      outline.appendSection(.pinned, isExpanded: expansion.pinned, content.pinned, area: .pinned)
    }
    for group in content.sections {
      let isExpanded = expansion.isExpanded(group.collapseID)
      outline.appendSection(.section(group.section), isExpanded: isExpanded, group.workspaces, area: .section(group.id))
    }
    outline.append([.header(.list(content.listTitle), isExpanded: expansion.list)])
    guard expansion.list else { return outline }

    for group in content.groups {
      outline.appendGroup(group, isExpanded: group.heading == nil || expansion.isExpanded(group.id))
    }
    return outline
  }

  private mutating func append(_ rows: [Row]) {
    items += rows.map(Item.init(row:))
  }

  private mutating func appendSection(
    _ header: Header, isExpanded: Bool, _ workspaces: [HomeSidebarWorkspace], area: Area
  ) {
    append([.header(header, isExpanded: isExpanded)])
    if isExpanded { append(HomeSidebarListEntry.flatten(workspaces).map { .entry($0, area: area) }) }
  }

  private mutating func appendGroup(_ group: HomeSidebarContent.Group, isExpanded: Bool) {
    if let heading = group.heading { append([.header(.group(group.id, heading), isExpanded: isExpanded)]) }
    if isExpanded {
      append(HomeSidebarListEntry.flatten(group.workspaces).map { .entry($0, area: .list(group: group.id)) })
    }
  }
}
