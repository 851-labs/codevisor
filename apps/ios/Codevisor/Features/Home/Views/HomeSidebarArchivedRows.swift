import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarArchivedRows {
  typealias Row = HomeSidebarCollectionRow

  let bots: [HomeSidebarBot]
  let workspaces: [HomeSidebarWorkspace]
  let hasMoreWorkspaces: Bool
  let isExpanded: Binding<Bool>
  let isConversation: Bool
  let actions: HomeSidebarActionHandler
  let isSelectable: Bool
  let botRows: (HomeSidebarBot, Row) -> [Row]
  let showMore: () -> Void

  var rows: [Row] {
    guard !bots.isEmpty || !workspaces.isEmpty else { return [] }
    guard isExpanded.wrappedValue else { return [header] }

    return [header] + carded(bots.flatMap(archivedBotRows) + workspaces.map(workspaceRow) + showMoreRows)
  }

  private var header: Row {
    let metrics = HomeSidebarHeaderMetrics(isConversation: isConversation)
    let toggle = HomeSidebarSectionToggle(
      title: "Archived", isExpanded: isExpanded, chevron: isConversation ? .conversation : .system
    )
    .font(.headline)
    .foregroundStyle(.secondary)
    .frame(minHeight: metrics.contentHeight, maxHeight: .infinity, alignment: .bottom)
    .accessibilityAddTraits(.isHeader)
    return Row(
      id: .archivedHeader, section: .archived, margins: isConversation ? nil : metrics.insets, background: .clear,
      hiddenSeparators: .all, content: AnyView(toggle))
  }

  private func carded(_ rows: [Row]) -> [Row] {
    guard !isConversation else { return rows }

    return rows.enumerated().map { index, row in
      var row = row
      row.background = .card(HomeSidebarCardEdges(top: index == 0, bottom: index == rows.count - 1))
      return row
    }
  }

  private func archivedBotRows(_ bot: HomeSidebarBot) -> [Row] {
    botRows(bot, Row(id: .archived(bot.id), section: .archived, selectionID: bot.id, content: AnyView(EmptyView())))
  }

  private func workspaceRow(_ workspace: HomeSidebarWorkspace) -> Row {
    let content = HomeSidebarWorkspaceRowView(workspace: workspace, actions: actions, isSelectionRow: isSelectable)
      .equatable()
    return Row(
      id: .archived(workspace.id), section: .archived,
      menu: HomeSidebarWorkspaceMenu(workspace: workspace, actions: actions).menu, content: AnyView(content))
  }

  private var showMoreRows: [Row] {
    guard hasMoreWorkspaces else { return [] }

    let button = Button("Show More", action: showMore)
      .foregroundStyle(.secondary)
    return [Row(id: .showMore, section: .archived, content: AnyView(button))]
  }
}
