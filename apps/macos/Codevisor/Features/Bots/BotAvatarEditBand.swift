import SwiftUI

struct BotAvatarEditBand: View {
  private static let bandFraction = 0.3
  private static let textFraction = 0.2
  private static let scrimOpacity = 0.35

  let size: CGFloat

  var body: some View {
    Text("edit")
      .font(.system(size: size * Self.textFraction, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size * Self.bandFraction)
      .background(.black.opacity(Self.scrimOpacity))
      .accessibilityHidden(true)
  }
}
