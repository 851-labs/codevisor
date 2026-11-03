import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationTopBar: View {
  static let toolbarHeight: CGFloat = 52

  let bot: Bot
  let showsHeader: Bool
  let onOpenDetails: (() -> Void)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isPointerInTopBar = false

  static func height(showsHeader: Bool) -> CGFloat {
    showsHeader ? BotConversationHeader.height : toolbarHeight
  }

  static func animation(reduceMotion: Bool) -> Animation? {
    Motion.panel(reduceMotion: reduceMotion)
  }

  var body: some View {
    ZStack(alignment: .top) {
      FullScreenTopBarBackdrop(isVisible: isPointerInTopBar, height: Self.height(showsHeader: showsHeader))
      if showsHeader {
        BotConversationHeader(bot: bot, onOpenDetails: onOpenDetails)
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
      }
    }
    .animation(Self.animation(reduceMotion: reduceMotion), value: showsHeader)
    .ignoresSafeArea(edges: .top)
    .background {
      FullScreenTopBarHover(bandHeight: Self.height(showsHeader: showsHeader)) { isPointerInTopBar = $0 }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
  }
}
