import SwiftUI

public enum MarkdownBlockChrome: Sendable, Equatable {
  case standard
  case bubble

  public var drawsFrame: Bool { self == .standard }

  var codeInsets: (horizontal: CGFloat, vertical: CGFloat) {
    switch self {
    case .standard: (10, 10)
    case .bubble: (10, 6)
    }
  }
}

extension EnvironmentValues {
  @Entry public var markdownBlockChrome: MarkdownBlockChrome = .standard
}
