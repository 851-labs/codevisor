import Testing
@testable import CodevisorUI

@MainActor
@Suite("Browser page closing")
struct BrowserPageClosingTests {
  @Test func quittingKeepsTabsAndOnlyAPageClosingItselfClosesItsTab() {
    let closing = BrowserPageClosing()
    #expect(!closing.closesTab(whenClosedByPage: false))
    #expect(closing.closesTab(whenClosedByPage: true))
    closing.appWillClosePages()
    #expect(!closing.closesTab(whenClosedByPage: true))
  }
}
