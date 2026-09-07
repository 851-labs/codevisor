import AppKit
import SwiftUI
import Testing
@testable import CodevisorUI

struct BrowserPageAppearanceTests {
  @Test func usesPageBackgroundWithoutTheme() {
    let appearance = BrowserPageAppearance(background: .black, theme: nil)
    #expect(appearance.chromeScheme == .dark)
    #expect(appearance.chromeColor == Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
  }

  @Test func themeTakesPrecedenceForBrowserChrome() {
    let appearance = BrowserPageAppearance(background: .black, theme: .white)
    #expect(appearance.chromeScheme == .light)
    #expect(appearance.chromeColor == Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1))
  }

  @Test func translucentThemeCompositesOverPage() {
    let appearance = BrowserPageAppearance(background: .black, theme: NSColor.white.withAlphaComponent(0.5))
    #expect(appearance.chromeColor == Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 1))
    #expect(appearance.chromeScheme == .light)
  }

  @Test func transparentThemeFallsBackToBackground() {
    #expect(
      BrowserPageAppearance(background: .black, theme: .clear) == BrowserPageAppearance(background: .black, theme: nil))
    #expect(BrowserPageAppearance(background: .white, theme: nil).chromeScheme == .light)
  }
}
