import CodevisorCore
import SwiftUI

public struct BotMascotAvatar: View {
  private static let scale = 1.1
  private static let drop = 0.12
  private static let fill = LinearGradient(
    colors: [Color(white: 0.97), Color(white: 0.88)],
    startPoint: .top,
    endPoint: .bottom
  )

  let mascot: ServerBotMascot
  let serverId: String
  let size: CGFloat

  public init(mascot: ServerBotMascot, serverId: String, size: CGFloat) {
    self.mascot = mascot
    self.serverId = serverId
    self.size = size
  }

  public var body: some View {
    BotMascotImage(mascot: mascot, serverId: serverId)
      .frame(width: size * Self.scale, height: size * Self.scale)
      .offset(y: size * Self.drop)
      .frame(width: size, height: size)
      .background(Self.fill)
      .clipShape(.circle)
  }
}
