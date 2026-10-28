import Foundation
import Testing

@testable import CodevisorUI

struct WebPaneNavigationTests {
  private let paneOrigin = WebPaneOrigin(url: URL(string: "http://127.0.0.1:4300/v1/plugins/panes/token/")!)

  private func decide(_ url: String, isMainFrame: Bool?) -> WebPaneNavigation {
    WebPaneNavigation.decide(url: URL(string: url), isMainFrame: isMainFrame, allowedOrigin: paneOrigin)
  }

  @Test("A pane's App frame loads from the loopback twin of the pane's own origin")
  func appFrameOnTwinOrigin() {
    #expect(decide("http://localhost:4300/v1/plugins/panes/token/frame", isMainFrame: false) == .allow)
  }

  @Test("Frames inside a pane may load web, data, blob and about pages, and nothing else")
  func subframeSchemes() {
    for url in ["https://maps.example.com/embed", "data:text/html,hi", "blob:http://localhost:4300/1", "about:blank"] {
      #expect(decide(url, isMainFrame: false) == .allow)
    }
    for url in ["file:///etc/passwd", "javascript:alert(1)", "codevisor://open"] {
      #expect(decide(url, isMainFrame: false) == .cancel)
    }
  }

  @Test("The pane itself stays on its origin and sends other web links to the browser")
  func mainFrame() {
    let outside = "https://www.example.com/listing"

    #expect(decide("http://127.0.0.1:4300/v1/plugins/panes/token/next", isMainFrame: true) == .allow)
    #expect(
      decide("http://localhost:4300/v1/plugins/panes/token/", isMainFrame: true)
        == .openExternally(URL(string: "http://localhost:4300/v1/plugins/panes/token/")!))
    #expect(decide(outside, isMainFrame: true) == .openExternally(URL(string: outside)!))
    #expect(decide(outside, isMainFrame: nil) == .openExternally(URL(string: outside)!))
    #expect(decide("file:///etc/passwd", isMainFrame: true) == .cancel)
  }
}
