import CodevisorCore
import SwiftUI

public struct BotMascotFigure: View {
  private static let overhang: CGFloat = 1.2

  let mascot: ServerBotMascot
  let serverId: String
  let slot: CGFloat
  let motion: BotMascotMotion

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isWindowVisible = true
  @State private var isOnScreen = false

  public init(mascot: ServerBotMascot, serverId: String, slot: CGFloat, motion: BotMascotMotion = .still) {
    self.mascot = mascot
    self.serverId = serverId
    self.slot = slot
    self.motion = motion
  }

  public var body: some View {
    Group {
      if let playing {
        BotMascotRiveView(mascot: mascot, serverId: serverId, mode: playing)
      } else {
        BotMascotImage(mascot: mascot, serverId: serverId, kind: .figure)
      }
    }
    .frame(width: figureSide, height: figureSide)
    .frame(width: slot, height: slot, alignment: .bottom)
    .background { BotMascotWindowVisibility(isVisible: $isWindowVisible) }
    .onAppear { isOnScreen = true }
    .onDisappear { isOnScreen = false }
  }

  private var figureSide: CGFloat {
    slot * Self.overhang
  }

  private var playing: BotMascotRiveMode? {
    guard canAnimate else { return nil }
    return motion.riveMode
  }

  private var canAnimate: Bool {
    !reduceMotion && isWindowVisible && isOnScreen
  }
}
