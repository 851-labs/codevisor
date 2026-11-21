import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarOutlineRows {
  typealias Row = HomeSidebarCollectionRow

  let outline: HomeSidebarOutline
  let sections: [CustomSection]
  let sectionActions: HomeSidebarSectionActions
  let actions: HomeSidebarActionHandler
  let isSelectable: Bool
  let isConversation: Bool
  var selectedID: UUID? = nil
  let expansion: (HomeSidebarOutline.Header) -> Binding<Bool>
  let botRows: (HomeSidebarBot, Row) -> [Row]

  var rows: [Row] {
    outline.items.enumerated().flatMap { index, item in rows(for: item, at: index) }
  }

  func move(_ source: Int, to destination: Int) {
    guard let move = HomeSidebarOutlineMove.resolve(moving: source, to: destination, in: outline.items) else { return }

    switch move {
    case let .bot(bot, placement): actions.actions.placeBot(bot, placement)
    case let .workspace(id, placement, siblings, movesSection):
      actions.actions.placeWorkspace(id, placement, siblings, movesSection)
    case let .nested(.workspace(id, target, among)): actions.actions.reorder(id, target, among)
    case let .nested(.tab(tabId, successor, workspace)): actions.actions.moveTab(tabId, successor, workspace)
    case let .section(id, index): sectionActions.reorder(id, index)
    }
  }

  private func rows(for item: HomeSidebarOutline.Item, at index: Int) -> [Row] {
    switch item.row {
    case let .header(header, _):
      [headerRow(header, item: item, at: index)]
    case let .bot(bot, section):
      botRows(bot, itemRow(item, at: index, member: section, content: AnyView(EmptyView())))
    case let .entry(entry, area):
      [entryRow(entry, item: item, at: index, member: area.section)]
    }
  }

  private func headerRow(_ header: HomeSidebarOutline.Header, item: HomeSidebarOutline.Item, at index: Int) -> Row {
    let metrics = HomeSidebarHeaderMetrics(isConversation: isConversation, isFirst: index == 0)
    let content = HomeSidebarHeaderRow(
      header: header, isExpanded: expansion(header), isConversation: isConversation, isFirst: index == 0)
    guard !header.isGroup else {
      return Row(id: .outline(item.id), outlineIndex: index, menu: newChatMenu(for: header), content: AnyView(content))
    }

    return Row(
      id: .outline(item.id), outlineIndex: index, drag: header.customSection.map(Row.Drag.section),
      startsBlock: header.startsBlock, margins: metrics.insets, background: .clear,
      hiddenSeparators: isConversation ? .bottom : .all, previewTopInset: metrics.gap, menu: sectionMenu(for: header),
      content: AnyView(content))
  }

  private func itemRow(_ item: HomeSidebarOutline.Item, at index: Int, member: UUID?, content: AnyView) -> Row {
    Row(
      id: .outline(item.id), outlineIndex: index, drag: .item, member: member,
      background: cardEdges(of: item, at: index).map(Row.Background.card) ?? .system,
      selectionID: item.id.itemID, content: content)
  }

  private func entryRow(
    _ entry: HomeSidebarListEntry, item: HomeSidebarOutline.Item, at index: Int, member: UUID?
  )
    -> Row
  {
    var row = itemRow(
      item, at: index, member: member,
      content: AnyView(HomeSidebarEntryRow(entry: entry, actions: actions, isSelectable: isSelectable)))
    row.menu = entryMenu(entry)
    return row
  }

  private func entryMenu(_ entry: HomeSidebarListEntry) -> HomeSidebarMenu {
    switch entry.row {
    case let .workspace(workspace):
      HomeSidebarWorkspaceMenu(workspace: workspace, actions: actions, sections: entry.depth == 0 ? sections : []).menu
    case let .tab(tab, owner):
      HomeSidebarTabMenu(row: tab, workspace: owner.workspace, actions: actions).menu
    }
  }

  private func cardEdges(of item: HomeSidebarOutline.Item, at index: Int) -> HomeSidebarCardEdges? {
    guard !isConversation, !item.isHeader, item.id != selectedID.map(HomeSidebarOutline.RowID.item) else { return nil }
    return outline.cardEdges(at: index)
  }

  private func sectionMenu(for header: HomeSidebarOutline.Header) -> HomeSidebarMenu? {
    guard case let .section(section) = header else { return nil }
    return HomeSidebarSectionMenu(section: section, sections: sections, actions: sectionActions).menu
  }

  private func newChatMenu(for header: HomeSidebarOutline.Header) -> HomeSidebarMenu? {
    guard case let .group(_, heading) = header, let target = heading.newChatTarget, target.isBareMachine else {
      return nil
    }
    var menu = HomeSidebarMenu()
    menu.add(.action("New Chat", systemImage: "square.and.pencil") { actions.actions.newChat(target) })
    return menu
  }
}

extension HomeSidebarOutline.Header {
  fileprivate var isGroup: Bool {
    guard case .group = self else { return false }
    return true
  }

  fileprivate var customSection: UUID? {
    guard case let .section(section) = self else { return nil }
    return section.id
  }

  fileprivate var startsBlock: Bool {
    switch self {
    case .section, .list: true
    case .pinned, .group: false
    }
  }
}

extension HomeSidebarOutline.RowID {
  fileprivate var itemID: UUID? {
    guard case let .item(id) = self else { return nil }
    return id
  }
}
