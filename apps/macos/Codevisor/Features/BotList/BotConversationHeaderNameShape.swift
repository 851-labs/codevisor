import SwiftUI

nonisolated struct BotConversationHeaderNameShape: Shape {
  let avatarSize: CGFloat
  let overlap: CGFloat

  func path(in rect: CGRect) -> Path {
    let avatar = CGRect(
      x: rect.midX - avatarSize / 2,
      y: rect.minY + overlap - avatarSize,
      width: avatarSize,
      height: avatarSize
    )
    return Capsule().path(in: rect).subtracting(Path(ellipseIn: avatar))
  }
}
