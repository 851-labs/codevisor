import SwiftUI

public enum UserBubbleStyle: Sendable {
  case standard
  case accent

  public var fill: Color {
    switch self {
    case .standard: .bubbleBackground
    case .accent: .accentColor
    }
  }

  public var text: Color {
    switch self {
    case .standard: .primary
    case .accent: .white
    }
  }
}

extension EnvironmentValues {
  @Entry public var userBubbleStyle: UserBubbleStyle = .standard
}
