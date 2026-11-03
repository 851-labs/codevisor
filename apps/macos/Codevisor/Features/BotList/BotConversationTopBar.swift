import CodevisorCore
import SwiftUI

struct BotConversationTopBar: View {
  let bot: Bot
  let onOpenDetails: (() -> Void)?
  @State private var isPointerInTopBar = false

  var body: some View {
    ZStack(alignment: .top) {
      FullScreenTopBarBackdrop(isVisible: isPointerInTopBar)
      BotConversationHeader(bot: bot, onOpenDetails: onOpenDetails)
    }
    .ignoresSafeArea(edges: .top)
    .background {
      FullScreenTopBarHover(bandHeight: BotConversationHeader.height) { isPointerInTopBar = $0 }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
  }
}
