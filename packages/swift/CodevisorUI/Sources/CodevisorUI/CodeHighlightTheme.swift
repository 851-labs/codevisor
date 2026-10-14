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
