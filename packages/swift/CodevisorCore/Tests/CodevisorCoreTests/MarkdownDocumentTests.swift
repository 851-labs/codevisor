import Foundation
import Testing
@testable import CodevisorCore

@Suite("Markdown document paths and persistence")
struct MarkdownDocumentTests {
  @Test(arguments: [
    ("docs/audit.md", "/workspace/docs/audit.md"),
    ("./docs/../audit.md:42", "/workspace/audit.md"),
    ("audit.md:42:8", "/workspace/audit.md"),
    ("docs/My%20Audit.MD#results", "/workspace/docs/My Audit.MD"),
    ("/tmp/audit.md#L12-L24", "/tmp/audit.md"),
    ("file:///tmp/My%20Audit.md", "/tmp/My Audit.md"),
    ("~/notes/../audit.markdown", "~/audit.markdown"),
  ])
  func resolvesServerPaths(target: String, expected: String) {
    let path = MarkdownDocumentPath.resolve(target, relativeTo: "/workspace")
    #expect(path == expected)
    #expect(path.map(MarkdownDocumentPath.isMarkdown) == true)
  }

  @Test(arguments: ["https://example.com/a.md", "//example.com/a.md", "#results", "mailto:a@b.com"])
  func leavesExternalLinksAlone(target: String) {
    #expect(MarkdownDocumentPath.resolve(target, relativeTo: "/workspace") == nil)
  }

  @Test func resolvesLinksRelativeToDocument() {
    #expect(
      MarkdownDocumentPath.resolve("../guide.md", relativeTo: "/workspace/docs/audits")
        == "/workspace/docs/guide.md"
    )
    #expect(!MarkdownDocumentPath.isMarkdown("/workspace/readme.txt"))
  }

  @MainActor
  @Test func persistsAndSyncsDocumentIdentity() throws {
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .document, name: "Audit.md", terminalKey: id.uuidString,
      documentPath: "/workspace/docs/Audit.md"
    )
    let state = PaneGroupState(panes: [pane], selectedPaneId: id, isVisible: true)
    let restored = try JSONDecoder().decode(
      PaneGroupState.self, from: JSONEncoder().encode(state)
    )
    #expect(restored == state)
    let record = WorkspaceSyncModel.serverPane(
      from: pane, workspaceId: UUID(), createdAt: Date()
    )
    #expect(record.paneType == "markdown")
    #expect(record.resourceId == "/workspace/docs/Audit.md")
    #expect(WorkspaceSyncModel.descriptor(from: record) == pane)
  }
}
