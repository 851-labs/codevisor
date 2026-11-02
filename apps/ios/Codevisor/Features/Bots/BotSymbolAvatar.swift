import SwiftUI

struct BotSymbolAvatar: View {
  let symbolName: String
  let size: CGFloat

  var body: some View {
    Image(systemName: symbolName)
      .font(.system(size: size * 0.45, weight: .medium))
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Color.accentColor.gradient, in: .circle)
      .accessibilityHidden(true)
  }
}
