import CodevisorCore
import SwiftUI

public struct BotMascotFigure: View {
  private static let overhang: CGFloat = 1.2

  let bot: Bot
  let mascot: ServerBotMascot
  let slot: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isWindowVisible = true

  public init(bot: Bot, mascot: ServerBotMascot, slot: CGFloat) {
    self.bot = bot
    self.mascot = mascot
    self.slot = slot
  }

  public var body: some View {
    Group {
      if canAnimate {
        BotMascotRiveView(key: key, mascot: mascot)
      } else {
        BotMascotImage(mascot: mascot, serverId: bot.serverId, kind: .figure)
      }
    }
    .frame(width: figureSide, height: figureSide)
    .frame(width: slot, height: slot, alignment: .bottom)
    .background { BotMascotWindowVisibility(isVisible: $isWindowVisible) }
    .onChange(of: motion, initial: true) { _, motion in BotMascotStages.shared.stage(for: key).show(motion) }
  }

  private var key: BotMascotStageKey { BotMascotStageKey(bot) }

  private var motion: BotMascotMotion {
    BotMascotMotion(BotMascotActivitySource.shared.activity(of: bot), isOpen: BotMascotOpenBots.shared.isOpen(key))
  }

  private var figureSide: CGFloat {
    slot * Self.overhang
  }

  private var canAnimate: Bool {
    !reduceMotion && isWindowVisible
  }
}
