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

extension View {
  func botHeaderNameContactShadow(_ shape: BotConversationHeaderNameShape) -> some View {
    overlay(alignment: .top) {
      Circle()
        .fill(.black.opacity(0.3))
        .frame(width: shape.avatarSize, height: shape.avatarSize)
        .blur(radius: 2)
        .offset(y: shape.overlap - shape.avatarSize + 1.5)
        .allowsHitTesting(false)
    }
    .clipShape(shape)
  }
}
