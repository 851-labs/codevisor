import CoreGraphics

/// A native diff surface that can follow its file's shared horizontal scroll.
@MainActor
protocol DiffScrollSyncMember: AnyObject {
  /// Another hunk of the file scrolled: move to the same offset.
  func applySyncedOffset(_ offset: CGFloat)
  /// The widest hunk changed: refit, so every hunk can travel as far.
  func syncedContentWidthChanged()
}

/// Scrolls one file's hunks sideways together. A file renders each hunk as
/// its own native surface (folds sit between them), yet reads as one diff:
/// scrolling any hunk moves them all, and all share the widest hunk's
/// content width so their columns stay aligned at every offset.
@MainActor
final class DiffScrollSync {
  private struct Member {
    weak var view: DiffScrollSyncMember?
    var contentWidth: CGFloat
  }

  private(set) var offset: CGFloat = 0
  private var members: [ObjectIdentifier: Member] = [:]

  /// The widest live hunk's natural content width.
  var sharedContentWidth: CGFloat {
    members.values.filter { $0.view != nil }.map(\.contentWidth).max() ?? 0
  }

  func register(_ view: DiffScrollSyncMember) {
    let id = ObjectIdentifier(view)
    if members[id] == nil {
      members[id] = Member(view: view, contentWidth: 0)
    }
  }

  func unregister(_ view: DiffScrollSyncMember) {
    guard members.removeValue(forKey: ObjectIdentifier(view)) != nil else { return }
    notifyWidthChange(excluding: nil)
  }

  func report(contentWidth: CGFloat, from view: DiffScrollSyncMember) {
    let id = ObjectIdentifier(view)
    guard members[id]?.contentWidth != contentWidth else { return }
    let before = sharedContentWidth
    members[id] = Member(view: view, contentWidth: contentWidth)
    if sharedContentWidth != before { notifyWidthChange(excluding: id) }
  }

  /// A hunk scrolled (by the reader, not by this group): bring the rest
  /// along. Echoes of an offset the group already holds are ignored, which
  /// is what stops members that follow from re-broadcasting.
  func report(offset newOffset: CGFloat, from view: DiffScrollSyncMember) {
    guard abs(newOffset - offset) > 0.5 else { return }
    offset = newOffset
    let source = ObjectIdentifier(view)
    for (id, member) in members where id != source {
      member.view?.applySyncedOffset(newOffset)
    }
  }

  private func notifyWidthChange(excluding source: ObjectIdentifier?) {
    members = members.filter { $0.value.view != nil }
    for (id, member) in members where id != source {
      member.view?.syncedContentWidthChanged()
    }
  }
}
