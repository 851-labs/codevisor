import SwiftUI

/// The active Shiki highlight theme (stable key + full theme JSON), injected
/// at the themed root so code-rendering views outside StreamMarkdown — the
/// diff viewer — can highlight without reaching back to the ThemeManager.
struct CodeHighlightTheme: Equatable {
    let key: String
    let json: String

    /// The key is the theme id — a stable identity for the JSON — so
    /// equality (and SwiftUI environment diffing) skips the big string.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

extension EnvironmentValues {
    @Entry var codeHighlightTheme: CodeHighlightTheme?
}
