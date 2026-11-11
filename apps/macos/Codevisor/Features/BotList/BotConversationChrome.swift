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
    content
      .environment(\.transcriptTopChromeHeight, topChromeHeight)
      .toolbar(removing: isActive ? .title : nil)
      .overlay(alignment: .top) {
        if !isSplit {
          BotConversationTopBar(bot: bot, showsHeader: showsHeader, onOpenDetails: openDetails)
        }
      }
      .botMascotOpen(isActive ? bot : nil)
  }

  private var showsHeader: Bool {
    RootSidebarVisibility(panelLayout: panelLayout).hidesDockedColumn
  }

  private var topChromeHeight: CGFloat {
    isSplit ? 0 : BotConversationTopBar.height(showsHeader: showsHeader)
  }

  private var isSplit: Bool {
    let workspace = environment.navigationStore.workspaceEntries.entry(bot.workspaceId).workspace
    return (workspace?.centerTree.allGroups.count ?? 1) > 1
  }

  private var isActive: Bool {
    workspaceActivity?.isActive ?? true
  }

  private var openDetails: (() -> Void)? {
    guard !bot.isArchived else { return nil }
    return { onEditBot(bot) }
  }
}
