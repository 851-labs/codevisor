import CoreGraphics

@MainActor
protocol DiffScrollSyncMember: AnyObject {
  func applySyncedOffset(_ offset: CGFloat)
  func syncedContentWidthChanged()
}

@MainActor
final class DiffScrollSync {
  private struct Member {
    weak var view: DiffScrollSyncMember?
    var contentWidth: CGFloat
  }

  private(set) var offset: CGFloat = 0
  private var members: [ObjectIdentifier: Member] = [:]

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
