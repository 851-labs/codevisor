import Testing

@testable import CodevisorUI

struct FilePaneRenameTests {
  @Test func openFilesFollowARenamedFileOrFolder() {
    let renamed = { (path: String) in
      FilePaneModel.renamedPath(path, from: "/site/docs", to: "/site/guides")
    }
    #expect(renamed("/site/docs") == "/site/guides")
    #expect(renamed("/site/docs/intro.md") == "/site/guides/intro.md")
    #expect(renamed("/site/docs-old/intro.md") == nil)
    #expect(renamed("/site/readme.md") == nil)
  }
}
