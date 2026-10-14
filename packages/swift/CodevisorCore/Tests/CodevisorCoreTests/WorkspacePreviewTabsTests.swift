import Foundation
import Testing
@testable import CodevisorCore

struct WorkspacePreviewTabsTests {
  @Test("Previewed content reuses the preview tab, but open content is selected where it is")
  func previewReusesItsTab() throws {
    let preview = document("/repo/a.swift")
    let pinned = diff("b.swift", .unstaged)
    let previewTab = tab(preview)
    let workspace = makeWorkspace([previewTab, tab(pinned)])
    let previewLeaf = try #require(previewTab.root.allGroups.first?.id)

    #expect(
      workspace.openTarget(for: .diff(file: "c.swift", mode: .unstaged), preview: true, previewPaneId: preview.id)
        == .preview(paneId: preview.id, leafId: previewLeaf))
    #expect(
      workspace.openTarget(for: .diff(file: "b.swift", mode: .unstaged), preview: true, previewPaneId: preview.id)
        == .existing(paneId: pinned.id, leafId: workspace.centerTabs[1].root.allGroups[0].id))
    // The same file's staged changes are a different diff.
    #expect(
      workspace.openTarget(for: .diff(file: "b.swift", mode: .staged), preview: false, previewPaneId: preview.id)
        == .newTab)
  }

  @Test("A preview that was split, or turned into the file picker, is no longer reused")
  func changedPreviewOpensANewTab() {
    let preview = diff("a.swift", .staged)
    var split = tab(preview)
    let leaf = split.root.allGroups[0].id
    split.root = split.root.splitting(
      groupId: leaf, edge: .trailing, newGroupId: UUID(), newGroupState: .centerInitial(sessionId: UUID()))
    #expect(
      makeWorkspace([split]).openTarget(for: .document(path: "/repo/c.swift"), preview: true, previewPaneId: preview.id)
        == .newTab)

    let browsing = document("/repo/")
    #expect(
      makeWorkspace([tab(browsing)]).openTarget(
        for: .document(path: "/repo/c.swift"), preview: true, previewPaneId: browsing.id) == .newTab)
  }

  private func document(_ path: String) -> PaneDescriptorState {
    let id = UUID()
    return PaneDescriptorState(id: id, kind: .document, name: path, terminalKey: id.uuidString, documentPath: path)
  }

  private func diff(_ file: String, _ mode: ServerGitDiffMode) -> PaneDescriptorState {
    let id = UUID()
    return PaneDescriptorState(
      id: id, kind: .review, name: file, terminalKey: id.uuidString,
      review: ReviewPanePreferences(mode: mode, file: file))
  }

  private func tab(_ pane: PaneDescriptorState) -> WorkspaceTab {
    WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id)))
  }

  private func makeWorkspace(_ tabs: [WorkspaceTab]) -> Workspace {
    Workspace(
      name: "Preview tests", rootDirectory: "/repo", serverId: "local",
      projectId: UUID(), centerTabs: tabs, selectedCenterTabId: tabs[0].id, createdAt: Date(timeIntervalSince1970: 0)
    )
  }
}
