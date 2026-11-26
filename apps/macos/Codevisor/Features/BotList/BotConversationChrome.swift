import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationChrome: ViewModifier {
  let bot: Bot
  let onEditBot: (Bot) -> Void
  @Environment(AppEnvironment.self) private var environment
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @Environment(WorkspaceActivity.self) private var workspaceActivity: WorkspaceActivity?

  func body(content: Content) -> some View {
    let page = environment.botPages.page(of: bot)
    let isSplit = isSplit(showing: page)
    return
      content
      .environment(\.transcriptTopChromeHeight, topChromeHeight(showing: page, isSplit: isSplit))
      .environment(\.hidesWorkspaceTitle, page.agent == nil)
      .overlay(alignment: .top) {
        if !isSplit, page == .conversation {
          BotConversationTopBar(bot: bot, showsHeader: showsHeader, onOpenDetails: openDetails)
        }
      }
      .botMascotOpen(isActive ? bot : nil)
  }

  private var showsHeader: Bool {
    RootSidebarVisibility(panelLayout: panelLayout).hidesDockedColumn
  }

  private func topChromeHeight(showing page: BotPage, isSplit: Bool) -> CGFloat {
    guard !isSplit, page.agent == nil else { return 0 }

    return BotConversationTopBar.height(showsHeader: showsHeader)
  }

  private func isSplit(showing page: BotPage) -> Bool {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(bot.workspaceId).workspace else {
      return false
    }
    return WorkspaceLayoutPolicy.isSplit(workspace, showing: page, environment: environment)
  }

  private var isActive: Bool {
    workspaceActivity?.isActive ?? true
  }

  private var openDetails: (() -> Void)? {
    guard !bot.isArchived else { return nil }
    return { onEditBot(bot) }
  }
}
