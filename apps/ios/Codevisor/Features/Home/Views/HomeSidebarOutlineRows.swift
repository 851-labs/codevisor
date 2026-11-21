import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarOutlineRows<BotRow: View>: View {
  let outline: HomeSidebarOutline
  let sections: [CustomSection]
  let sectionActions: HomeSidebarSectionActions
  let actions: HomeSidebarActionHandler
  let isSelectable: Bool
  let isConversation: Bool
  var selectedID: UUID? = nil
  let expansion: (HomeSidebarOutline.Header) -> Binding<Bool>
  @ViewBuilder let botRow: (HomeSidebarBot) -> BotRow

  var body: some View {
    Section {
      ForEach(Array(outline.items.enumerated()), id: \.element.id) { index, item in
        row(item)
          .modifier(HomeSidebarCardRow(edges: cardEdges(of: item, at: index)))
          .moveDisabled(!item.isMovable)
      }
      .onMove(perform: move)
    }
    .listSectionSeparator(.hidden, edges: .top)
  }

  private func cardEdges(of item: HomeSidebarOutline.Item, at index: Int) -> HomeSidebarCardEdges? {
    guard !isConversation, !item.isHeader, item.id != selectedID.map(HomeSidebarOutline.RowID.item) else { return nil }
    return outline.cardEdges(at: index)
  }

  @ViewBuilder
  private func row(_ item: HomeSidebarOutline.Item) -> some View {
    switch item.row {
    case let .header(header, _):
      HomeSidebarHeaderRow(
        header: header, isExpanded: expansion(header), isConversation: isConversation,
        isFirst: outline.items.first?.id == item.id, sectionMenu: sectionMenu(for: header),
        onNewChat: newChat(for: header))
    case let .bot(bot, _):
      botRow(bot)
    case let .entry(entry, _):
      HomeSidebarEntryRow(entry: entry, sections: sections, actions: actions, isSelectable: isSelectable)
    }
  }

  private func sectionMenu(for header: HomeSidebarOutline.Header) -> HomeSidebarSectionMenu? {
    guard case let .section(section) = header else { return nil }
    return HomeSidebarSectionMenu(section: section, sections: sections, actions: sectionActions)
  }

  private func newChat(for header: HomeSidebarOutline.Header) -> (() -> Void)? {
    guard case let .group(_, heading) = header, let target = heading.newChatTarget, target.isBareMachine else {
      return nil
    }
    return { actions.actions.newChat(target) }
  }

  private func move(_ source: IndexSet, to destination: Int) {
    guard let index = source.first,
      let move = HomeSidebarOutlineMove.resolve(moving: index, to: destination, in: outline.items)
    else { return }

    switch move {
    case let .bot(bot, placement): actions.actions.placeBot(bot, placement)
    case let .workspace(id, placement, siblings, movesSection):
      actions.actions.placeWorkspace(id, placement, siblings, movesSection)
    case let .nested(.workspace(id, target, among)): actions.actions.reorder(id, target, among)
    case let .nested(.tab(tabId, successor, workspace)): actions.actions.moveTab(tabId, successor, workspace)
    case let .section(id, index): sectionActions.reorder(id, index)
    }
  }
}
