import Foundation
import Testing

@testable import CodevisorUI

struct FileHTMLPreviewNavigationTests {
  private let address = FileHTMLPreviewAddress(document: "/work/site/index.html", rootPath: "/work")

  private func decide(_ url: String, mainFrame: Bool = true, link: Bool = true) -> FileHTMLPreviewNavigation {
    FileHTMLPreviewNavigation.decide(
      url: URL(string: url), isMainFrame: mainFrame, isLinkActivated: link, address: address)
  }

  @Test("The page itself and its anchors load in place")
  func page() {
    #expect(decide("codevisor-file://preview/work/site/index.html", link: false) == .allow)
    #expect(decide("codevisor-file://preview/work/site/index.html#usage") == .allow)
  }

  @Test("Clicked links open local files in the file pane and web pages in the browser")
  func links() {
    #expect(decide("codevisor-file://preview/work/site/about.html") == .openFile("/work/site/about.html"))
    #expect(decide("codevisor-file://preview/work/src/main.swift#L12") == .openFile("/work/src/main.swift#L12"))
    #expect(decide("file:///work/notes.md") == .openFile("/work/notes.md"))
    #expect(decide("https://example.com/docs") == .openWebLink(URL(string: "https://example.com/docs")!))
    #expect(decide("mailto:a@example.com") == .openExternally(URL(string: "mailto:a@example.com")!))
    #expect(decide("javascript:alert(1)") == .cancel)
  }

  @Test("Scripts can't navigate the preview away or open panes on their own")
  func scriptedNavigation() {
    #expect(decide("https://example.com/", link: false) == .cancel)
    #expect(decide("codevisor-file://preview/work/site/about.html", link: false) == .cancel)
  }

  @Test("Frames may load web, data, blob, about and preview pages")
  func frames() {
    for url in [
      "https://www.youtube.com/embed/1", "data:text/html,hi", "about:blank",
      "codevisor-file://preview/work/site/a.html",
    ] {
      #expect(decide(url, mainFrame: false, link: false) == .allow)
    }
    #expect(decide("file:///etc/hosts", mainFrame: false, link: false) == .cancel)
  }
}
