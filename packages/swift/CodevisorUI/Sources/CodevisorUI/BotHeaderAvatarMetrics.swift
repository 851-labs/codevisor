import SwiftUI

public enum BotHeaderAvatarMetrics {
  public static let overlap: CGFloat = 4
}

extension View {
  public func botHeaderAvatarShadow() -> some View {
    shadow(color: .black.opacity(0.22), radius: 2, y: 1.5)
  }
}
