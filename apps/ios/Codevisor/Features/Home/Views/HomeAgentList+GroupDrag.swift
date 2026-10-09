import CodevisorCore
import CodevisorUI
import SwiftUI

/// Reordering folders (or projects) from their headers, as list rows do: a
/// long press shows the group's menu, and moving the finger lifts it out of
/// the menu into a drag. The lifted group collapses to its header, the
/// others slide past as the drag moves, and letting go commits the order.
extension HomeAgentList {
  struct GroupDrag: Equatable {
    let id: String
    var order: [String]
    /// Where the drag is, in global space. The header is a line tall, so
    /// its middle is taken to be under the finger.
    var fingerY: CGFloat?
  }

  /// The groups in the order the drag has them in, while one is lifted.
  func displayed(_ groups: [SidebarGroup]) -> [SidebarGroup] {
    guard let groupDrag else { return groups }
    let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let shown = groupDrag.order.compactMap { byId[$0] }
    // A group added or removed mid-drag ends the drag's authority.
    return shown.count == groups.count ? shown : groups
  }

  /// A group's header, with its menu on a long press (folders only) and a
  /// drag out of that press to reorder it. Section headers don't take
  /// SwiftUI's context menus or drags, so UIKit's interactions carry them.
  func draggableHeader<Header: View>(
    _ group: SidebarGroup, in groups: [SidebarGroup], menu: [HomeGroupHeaderAction],
    @ViewBuilder header: () -> Header
  ) -> some View {
    ZStack {
      // The measured slot.
      Color.clear
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .global)
        } action: { frame in
          headerFrames.frames[group.id] = frame
          // The collapse moves every slot; keep the hole under the drag as
          // they settle, not only when the drag moves.
          if groupDrag != nil { reconcileGroupOrder() }
        }
      HomeGroupHeaderHost(
        title: group.title, content: header(), menu: menu,
        onBegin: { beginGroupDrag(group, in: groups) },
        onMove: { updateGroupDrag(fingerY: $0) },
        onEnd: { endGroupDrag(in: groups) }
      )
      // The drag preview is what the user sees moving; the slot stays a
      // hole until the drop.
      .opacity(groupDrag?.id == group.id ? 0 : 1)
    }
  }

  /// The list's part in a group drag: scrolling held still while the
  /// other groups reflow around the lifted one.
  func groupDragChrome<Content: View>(_ content: Content) -> some View {
    content
      .scrollDisabled(groupDrag != nil)
      .animation(Motion.listReflow(reduceMotion: reduceMotion), value: groupDrag?.order)
      .sensoryFeedback(.selection, trigger: groupDrag?.order)
  }

  private func beginGroupDrag(_ group: SidebarGroup, in groups: [SidebarGroup]) {
    withAnimation(.snappy(duration: 0.28)) {
      groupDrag = GroupDrag(id: group.id, order: groups.map(\.id))
    }
  }

  func updateGroupDrag(fingerY: CGFloat) {
    guard var current = groupDrag, current.fingerY != fingerY else { return }
    current.fingerY = fingerY
    groupDrag = current
    reconcileGroupOrder()
  }

  /// Slot the lifted group after every other group whose middle the drag
  /// has passed. A group spans its header and workspaces, down to the next
  /// header, so a tall one is crossed halfway down its workspaces.
  private func reconcileGroupOrder() {
    guard var current = groupDrag, let fingerY = current.fingerY else { return }
    let others = current.order.filter { $0 != current.id }
    let frames = headerFrames.frames
    let passed = others.indices.filter { index in
      guard let header = frames[others[index]] else { return false }
      let next = others.indices.contains(index + 1) ? frames[others[index + 1]]?.minY : nil
      let bottom = max(header.maxY, next ?? header.maxY)
      return (header.minY + bottom) / 2 < fingerY
    }.count
    var order = others
    order.insert(current.id, at: min(passed, others.count))
    guard order != current.order else { return }
    current.order = order
    groupDrag = current
  }

  /// Commit the order; the list then shows it from the store.
  func endGroupDrag(in groups: [SidebarGroup]) {
    guard let current = groupDrag else { return }
    if current.order != groups.map(\.id), let index = current.order.firstIndex(of: current.id),
      let group = groups.first(where: { $0.id == current.id })
    {
      if let folder = group.folder, let id = UUID(uuidString: folder.id) {
        navigation.moveFolder(id, to: index)
      } else if let projectId = group.projectId {
        navigation.moveProject(projectId, to: index, among: groups.compactMap(\.projectId))
      }
    }
    withAnimation(.snappy(duration: 0.28)) { groupDrag = nil }
  }
}

/// Group header frames in global space: `List` hosts each cell separately,
/// so a space named on the list doesn't resolve in them. A plain class,
/// deliberately not observed: headers move on every scroll tick and must
/// not re-render the list; the drag reads them on demand.
@MainActor
final class HomeGroupHeaderFrames {
  var frames: [String: CGRect] = [:]
}
