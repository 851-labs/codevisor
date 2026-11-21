import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarBotRows {
  typealias Row = HomeSidebarCollectionRow

  let actions: HomeSidebarActionHandler
  let isSelectable: Bool
  let selected: HomeSidebarSelection?
  let isConversation: Bool
  let tabExpansion: (UUID) -> Binding<Bool>

  func rows(_ bot: HomeSidebarBot, template: Row, sections: [CustomSection]?) -> [Row] {
    var row = template
    row.content = content(bot)
    row.menu = HomeSidebarBotMenu(bot: bot, actions: actions, sections: sections).menu
    guard let home = bot.home, bot.hasNestedRows, tabExpansion(bot.id).wrappedValue else { return [row] }

    return [row] + bot.tabs.map { tabRow($0, in: home, template: template) }
  }

  private func content(_ bot: HomeSidebarBot) -> AnyView {
    let row = HomeSidebarBotRowView(
      bot: bot, actions: actions, isSelectionRow: isSelectable, isOpen: selected == .bot(bot.id),
      isConversation: isConversation
    )
    guard bot.hasNestedRows else { return AnyView(row.equatable()) }

    return AnyView(
      HomeSidebarDisclosureBotRow(row: row, isExpanded: tabExpansion(bot.id), isConversation: isConversation))
  }

  private func tabRow(_ tab: HomeSidebarTabRow, in home: HomeSidebarWorkspace, template: Row) -> Row {
    let content = HomeSidebarTabRowView(
      row: tab, workspace: home.workspace, actions: actions, isSelectionRow: isSelectable
    )
    .equatable()
    .padding(.leading, HomeSidebarEntryRow.indent)
    return Row(
      id: .nested(tab.id), section: template.section, member: template.member, selectionID: tab.id,
      menu: HomeSidebarTabMenu(row: tab, workspace: home.workspace, actions: actions).menu, content: AnyView(content))
  }
}
