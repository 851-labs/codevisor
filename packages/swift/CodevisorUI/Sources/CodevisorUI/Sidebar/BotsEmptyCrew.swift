import CodevisorCore
import SwiftUI

struct BotsEmptyCrew: View {
  private static let leader = ServerBotMascot(color: "sunny", hat: "crown", eyewear: "none")
  private static let leftCompanion = ServerBotMascot(color: "mint", hat: "chef", eyewear: "none")
  private static let rightCompanion = ServerBotMascot(color: "lilac", hat: "wizard", eyewear: "specs")
  private static let leaderSide: CGFloat = 152
  private static let companionSide: CGFloat = 116
  private static let overlap: CGFloat = 40

  let serverId: String

  var body: some View {
    HStack(alignment: .bottom, spacing: -Self.overlap) {
      figure(Self.leftCompanion, side: Self.companionSide)
      figure(Self.leader, side: Self.leaderSide)
        .zIndex(1)
      figure(Self.rightCompanion, side: Self.companionSide)
    }
  }

  private func figure(_ mascot: ServerBotMascot, side: CGFloat) -> some View {
    BotMascotImage(mascot: mascot, serverId: serverId, kind: .figure)
      .frame(width: side, height: side)
  }
}
