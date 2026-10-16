import CodevisorTheming
import SwiftUI

public struct CodeHighlightTheme: Equatable {
  public let key: String
  public let json: String

  public init(key: String, json: String) {
    self.key = key
    self.json = json
  }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

extension EnvironmentValues {
  @Entry public var codeHighlightTheme: CodeHighlightTheme?
}

extension CodeHighlightTheme {
  @MainActor
  public static func bundled(isDark: Bool) -> CodeHighlightTheme? {
    SyntaxTheme.json(isDark: isDark).map { CodeHighlightTheme(key: SyntaxTheme.key(isDark: isDark), json: $0) }
  }
}
