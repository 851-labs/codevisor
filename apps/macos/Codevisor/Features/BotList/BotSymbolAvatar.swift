import SwiftUI

struct BotSymbolAvatar: View {
  private static let fill = LinearGradient(
    colors: [Color(red: 0.65, green: 0.67, blue: 0.72), Color(red: 0.52, green: 0.54, blue: 0.58)],
    startPoint: .top,
    endPoint: .bottom
  )

  let symbolName: String
  let size: CGFloat

  var body: some View {
    Image(systemName: symbolName)
      .font(.system(size: size * 0.45, weight: .medium))
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Self.fill, in: .circle)
      .accessibilityHidden(true)
  }
}
