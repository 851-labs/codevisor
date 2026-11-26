import CodevisorCore
import SwiftUI

struct RootTitlebar: View {
  let selection: SidebarSelection?
  let panelLayout: AdaptivePanelLayout
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    TransparentTitlebar(isTransparent: showsBotChrome, hoverBandHeight: hoverBandHeight)
      .frame(width: 0, height: 0)
  }

  private var showsBotChrome: Bool {
    guard case let .bot(serverId, botId) = selection else { return false }
    guard let bot = environment.bots.bot(serverId: serverId, id: botId) else { return true }

    return environment.botPages.page(of: bot).agent == nil
  }

  private var hoverBandHeight: CGFloat {
    BotConversationTopBar.height(showsHeader: RootSidebarVisibility(panelLayout: panelLayout).hidesDockedColumn)
  }
}
