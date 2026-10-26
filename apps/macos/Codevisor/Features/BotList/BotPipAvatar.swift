import AppKit
import SwiftUI

struct BotPipAvatar: View {
  private static let scale = 1.1
  private static let drop = 0.12
  private static let fill = LinearGradient(
    colors: [Color(white: 0.97), Color(white: 0.88)],
    startPoint: .top,
    endPoint: .bottom
  )

  let image: NSImage
  let size: CGFloat

  var body: some View {
    Image(nsImage: image)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size * Self.scale, height: size * Self.scale)
      .offset(y: size * Self.drop)
      .frame(width: size, height: size)
      .background(Self.fill)
      .clipShape(.circle)
      .accessibilityHidden(true)
  }
}
