import Foundation

/// What an editor-style preview tab can show: a document, or one file's
/// diff opened from source control.
public enum PreviewContent: Equatable, Sendable {
  case document(path: String)
  /// A repository-relative file compared in `mode` (staged or unstaged).
  case diff(file: String, mode: ServerGitDiffMode)
}

/// Where opening previewable content lands in a workspace.
public enum PreviewOpenTarget: Equatable, Sendable {
  /// A pane already shows the content; select it.
  case existing(paneId: UUID, leafId: UUID)
  /// The preview pane swaps what it shows for this content.
  case preview(paneId: UUID, leafId: UUID)
  /// The content gets a tab of its own.
  case newTab
}

extension PaneDescriptorState {
  /// What this pane shows, when a preview tab could have shown it: a
  /// document (not the empty file picker) or a single file's diff.
  public var previewContent: PreviewContent? {
    switch kind {
    case .document:
      guard let documentPath, !documentPath.hasSuffix("/") else { return nil }
      return .document(path: documentPath)
    case .review:
      guard let review, let file = review.file else { return nil }
      return .diff(file: file, mode: review.mode)
    default:
      return nil
    }
  }
}

extension Workspace {
  /// Like an editor's preview tab: content opened as a preview reuses the
  /// workspace's preview pane while that pane is still alone in its tab and
  /// still shows previewable content. Anything else (content already open, a
  /// pinned open, a preview that was split or became something else)
  /// behaves like a normal open.
  public func openTarget(for content: PreviewContent, preview: Bool, previewPaneId: UUID?) -> PreviewOpenTarget {
    for tab in centerTabs {
      for leaf in tab.root.allGroups {
        if let pane = leaf.state.panes.first(where: { $0.previewContent == content }) {
          return .existing(paneId: pane.id, leafId: leaf.id)
        }
      }
    }
    if preview, let leafId = reusablePreviewLeaf(previewPaneId), let previewPaneId {
      return .preview(paneId: previewPaneId, leafId: leafId)
    }
    return .newTab
  }

  /// The leaf holding the preview pane, when that pane is still the only
  /// thing in its tab and still shows previewable content.
  public func reusablePreviewLeaf(_ paneId: UUID?) -> UUID? {
    guard let paneId else { return nil }
    for tab in centerTabs {
      let leaves = tab.root.allGroups
      guard leaves.count == 1, let leaf = leaves.first, leaf.state.panes.count == 1,
        let pane = leaf.state.panes.first, pane.id == paneId
      else { continue }
      return pane.previewContent == nil ? nil : leaf.id
    }
    return nil
  }
}
