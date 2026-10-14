import Testing
import WebKit

@testable import CodevisorUI

@MainActor
@Suite("Browser content mode")
struct BrowserContentModeTests {
  @Test("Narrow panes request the mobile site")
  func narrowIsMobile() {
    #expect(BrowserPaneModel.contentMode(forWidth: 320) == .mobile)
    #expect(BrowserPaneModel.contentMode(forWidth: 699) == .mobile)
  }

  @Test("Wide panes, and panes with no width yet, keep WebKit's choice")
  func wideIsRecommended() {
    #expect(BrowserPaneModel.contentMode(forWidth: 700) == .recommended)
    #expect(BrowserPaneModel.contentMode(forWidth: 1024) == .recommended)
    #expect(BrowserPaneModel.contentMode(forWidth: 0) == .recommended)
  }
}
