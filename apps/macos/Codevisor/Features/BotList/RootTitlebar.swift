import SwiftUI

struct RootTitlebar: View {
  let isBotConversation: Bool
  let panelLayout: AdaptivePanelLayout

  var body: some View {
    TransparentTitlebar(isTransparent: isBotConversation, hoverBandHeight: hoverBandHeight)
      .frame(width: 0, height: 0)
  }

  private var hoverBandHeight: CGFloat {
    BotConversationTopBar.height(showsHeader: RootSidebarVisibility(panelLayout: panelLayout).hidesDockedColumn)
  }
}
