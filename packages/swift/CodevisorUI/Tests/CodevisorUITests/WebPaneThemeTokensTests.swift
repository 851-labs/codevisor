import Foundation
import Testing

@testable import CodevisorUI

@Suite("WebPaneThemeTokens")
struct WebPaneThemeTokensTests {
  private static let frozenVariables = [
    "--codevisor-bg",
    "--codevisor-fg",
    "--codevisor-border",
    "--codevisor-accent",
    "--codevisor-font-family",
    "--codevisor-diff-added",
    "--codevisor-diff-removed",
    "--codevisor-diff-added-bg",
    "--codevisor-diff-removed-bg",
    "--codevisor-status-ok",
    "--codevisor-status-warn",
    "--codevisor-status-error",
  ]

  @Test("System themes emit the full frozen variable set in both modes")
  func systemVariableCoverage() {
    for isDark in [false, true] {
      let tokens = WebPaneThemeTokens(palette: nil, isDark: isDark)
      #expect(tokens.mode == (isDark ? "dark" : "light"))
      #expect(tokens.background != nil)
      for name in Self.frozenVariables {
        #expect(tokens.variables[name] != nil, "missing \(name) (isDark: \(isDark))")
      }
    }
    #expect(
      WebPaneThemeTokens(palette: nil, isDark: false)
        != WebPaneThemeTokens(palette: nil, isDark: true)
    )
  }
}
