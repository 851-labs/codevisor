import SwiftUI

struct BotsEmptyCrew: View {
  private static let leader = "bots-empty-crew-leader"
  private static let leftCompanion = "bots-empty-crew-left"
  private static let rightCompanion = "bots-empty-crew-right"
  private static let leaderSide: CGFloat = 152
  private static let companionSide: CGFloat = 116
  private static let overlap: CGFloat = 40

  var body: some View {
    HStack(alignment: .bottom, spacing: -Self.overlap) {
      figure(Self.leftCompanion, side: Self.companionSide)
      figure(Self.leader, side: Self.leaderSide)
        .zIndex(1)
      figure(Self.rightCompanion, side: Self.companionSide)
    }
  }

  private func figure(_ name: String, side: CGFloat) -> some View {
    Image(decorative: name, bundle: .module)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: side, height: side)
  }
}
