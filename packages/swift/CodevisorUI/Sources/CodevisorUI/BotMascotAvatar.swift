import CodevisorCore
import SwiftUI

public struct BotMascotAvatar: View {
  private static let scale = 1.32
  private static let drop = 0.12
  private static let fill = LinearGradient(
    colors: [Color(white: 0.97), Color(white: 0.88)],
    startPoint: .top,
    endPoint: .bottom
  )

  let mascot: ServerBotMascot
  let size: CGFloat

  public init(mascot: ServerBotMascot, size: CGFloat) {
    self.mascot = mascot
    self.size = size
  }

  public var body: some View {
    BotMascotImage(mascot: mascot)
      .frame(width: size * Self.scale, height: size * Self.scale)
      .offset(y: size * Self.drop)
      .frame(width: size, height: size)
      .background(Self.fill)
      .clipShape(.circle)
  }
}
