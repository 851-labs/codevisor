import CodevisorCore
import SwiftUI

enum ToolIconMetrics {
  static let columnWidth: CGFloat = 18
  static let symbolWeight: Font.Weight = .regular

  static var side: CGFloat {
    #if os(iOS)
      15
    #else
      14
    #endif
  }

  static var textStyle: Font.TextStyle {
    #if os(iOS)
      .subheadline
    #else
      .callout
    #endif
  }

  static var spacing: CGFloat {
    #if os(iOS)
      6
    #else
      8
    #endif
  }

  static var labelInset: CGFloat { columnWidth + spacing }
}

enum ToolIconKind {
  case symbol
  case mark
  case tile
  case appIcon

  init(symbol: String) {
    self = symbol == ToolCallIcon.codevisorMark ? .mark : .symbol
  }

  init(artwork: ToolCallIcon.Artwork) {
    switch artwork {
    case .site, .mcpServer: self = .tile
    case .app: self = .appIcon
    }
  }

  var opticalScale: CGFloat {
    switch self {
    case .symbol: 0.93
    case .mark: 0.86
    case .tile: 0.86
    case .appIcon: 1.07
    }
  }

  func size(in side: CGFloat) -> CGFloat {
    (side * opticalScale).rounded()
  }
}

extension EnvironmentValues {
  @Entry var toolIconSide = ToolIconMetrics.side
}
