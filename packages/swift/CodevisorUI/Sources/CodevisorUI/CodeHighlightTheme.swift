import SwiftUI

/// The active VS Code/Shiki highlight theme (stable key + full theme JSON), injected
/// at the themed root so code-rendering views outside StreamMarkdown — the
/// diff viewer — can highlight without reaching back to the ThemeManager.
public struct CodeHighlightTheme: Equatable {
  public let key: String
  public let json: String

  public init(key: String, json: String) {
    self.key = key
    self.json = json
  }

  /// The key is the theme id — a stable identity for the JSON — so
  /// equality (and SwiftUI environment diffing) skips the big string.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

extension EnvironmentValues {
  @Entry public var codeHighlightTheme: CodeHighlightTheme?
}
