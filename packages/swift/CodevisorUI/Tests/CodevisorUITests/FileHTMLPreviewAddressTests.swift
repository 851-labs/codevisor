import Foundation
import Testing

@testable import CodevisorUI

struct FileHTMLPreviewAddressTests {
  private let address = FileHTMLPreviewAddress(document: "/work/site/index.html", rootPath: "/work/app")

  @Test("Pages read files next to them and inside the workspace, and nothing else")
  func scope() {
    #expect(address.allows("/work/site/style.css"))
    #expect(address.allows("/work/site/img/logo.png"))
    #expect(address.allows("/work/app/shared.css"))
    #expect(!address.allows("/work/other/secret.txt"))
    #expect(!address.allows("/work/site-old/style.css"))
    #expect(!address.allows("/etc/hosts"))
  }

  @Test("Encoded dot segments can't climb out of the page's folder")
  func dotSegments() throws {
    let escape = try #require(URL(string: "codevisor-file://preview/work/site/..%2F..%2Fetc/hosts"))

    #expect(FileHTMLPreviewAddress.path(of: escape) == nil)
  }

  @Test("Paths round-trip through preview URLs, including spaces and home-relative paths")
  func roundTrip() {
    for path in ["/work/My Site/index.html", "~/Desktop/page.html", "/work/a#b?.html"] {
      #expect(FileHTMLPreviewAddress.path(of: FileHTMLPreviewAddress.url(for: path)) == path)
    }
  }
}
