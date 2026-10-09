import CodevisorCore
import CodevisorUI
import SwiftUI

/// Reordering folders (or projects) from their headers, in the one `List`:
/// a long press lifts the header and collapses just that group, the drag
/// moves it live past the others (which keep their workspaces showing), and
/// the drop commits the order and expands it again.
///
/// The lifted header is drawn as an overlay on the list, positioned only by
/// the finger; its own section keeps an invisible placeholder. That keeps it
/// out of the reflow animation: only the other groups animate past, and the
/// hole slides under the finger.
extension HomeAgentList {
  struct GroupDrag: Equatable {
    let id: String
    var order: [String]
    /// Where the header's center was when it lifted. Until the first drag
    /// sample this is where the finger is, so the floating header stays put
    /// while its own group collapses under it.
    let liftedMidY: CGFloat
    var fingerY: CGFloat?
    /// Where on the header the finger landed, relative to its center, so
    /// the header lifts in place instead of snapping under the finger.
    var grabOffset: CGFloat?
    /// Released: the floating header is gliding into its slot before its
    /// group expands.
    var isSettling = false
  }

  /// The groups in the order the drag has them in, while one is lifted.
  func displayed(_ groups: [SidebarGroup]) -> [SidebarGroup] {
    guard let groupDrag else { return groups }
    let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let shown = groupDrag.order.compactMap { byId[$0] }
    // A group added or removed mid-drag ends the drag's authority.
    return shown.count == groups.count ? shown : groups
  }

  func draggableHeader<Header: View>(
    _ group: SidebarGroup, in groups: [SidebarGroup], @ViewBuilder header: () -> Header
  ) -> some View {
    ZStack {
      // The measured slot: stays put while the header itself is lifted.
      Color.clear
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .global)
        } action: { frame in
          headerFrames.frames[group.id] = frame
          // The collapse moves every slot; keep the hole under the finger
          // as they settle, not only when the finger moves.
          if groupDrag != nil { reconcileGroupOrder() }
        }
      header()
        // The floating copy is what the user sees moving.
        .opacity(groupDrag?.id == group.id ? 0 : 1)
    }
    .gesture(
      WorkspaceReorderGesture(
        onBegan: { point in
          beginGroupDrag(group, in: groups)
          updateGroupDrag(fingerY: point.y)
        },
        onChanged: { point in updateGroupDrag(fingerY: point.y) },
        onEnded: { endGroupDrag(in: groups) }
      ))
  }

  /// The list's part in a group drag: scrolling held still, the others
  /// reflowing, and the lifted header floating over it all.
  func groupDragChrome<Content: View>(_ content: Content, groups: [SidebarGroup]) -> some View {
    content
      .scrollDisabled(groupDrag != nil)
      .animation(Motion.listReflow(reduceMotion: reduceMotion), value: groupDrag?.order)
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .global)
      } action: { frame in
        listFrame = frame
      }
      // Outside the reflow animation: the header answers the finger at once.
      .overlay(alignment: .topLeading) { floatingHeader(groups) }
      .sensoryFeedback(.impact(weight: .medium), trigger: liftFeedback)
      .sensoryFeedback(.selection, trigger: groupDrag?.order)
  }

  /// The lifted header in the list's space: where it lifted until the
  /// finger moves, then under the finger, gliding onto its slot on release.
  @ViewBuilder
  private func floatingHeader(_ groups: [SidebarGroup]) -> some View {
    if let drag = groupDrag, let group = groups.first(where: { $0.id == drag.id }),
      let slot = headerFrames.frames[drag.id]
    {
      let centerY = drag.isSettling ? slot.midY : liftedCenterY(drag)
      floatingHeaderLabel(group)
        .frame(width: slot.width, height: slot.height)
        .scaleEffect(drag.isSettling ? 1 : 1.03)
        .offset(x: slot.minX - listFrame.minX, y: centerY - slot.height / 2 - listFrame.minY)
        .allowsHitTesting(false)
        .transition(.identity)
    }
  }

  /// The header as its slot draws it, its menu button included.
  @ViewBuilder
  private func floatingHeaderLabel(_ group: SidebarGroup) -> some View {
    if group.folder != nil {
      HomeAgentSectionHeader(title: group.title, isExpanded: false) {
      } menu: {
        Group {}
      }
    } else {
      HomeAgentSectionHeader(title: group.title, isExpanded: false) {}
    }
  }

  private func beginGroupDrag(_ group: SidebarGroup, in groups: [SidebarGroup]) {
    liftFeedback += 1
    withAnimation(.snappy(duration: 0.28)) {
      groupDrag = GroupDrag(
        id: group.id, order: groups.map(\.id), liftedMidY: headerFrames.frames[group.id]?.midY ?? 0)
    }
  }

  private func liftedCenterY(_ drag: GroupDrag) -> CGFloat {
    guard let fingerY = drag.fingerY else { return drag.liftedMidY }
    return fingerY - (drag.grabOffset ?? 0)
  }

  private func updateGroupDrag(fingerY: CGFloat) {
    guard var current = groupDrag, !current.isSettling else { return }
    if current.grabOffset == nil {
      // Against the frozen lift point: the slot has already started moving
      // with the collapse, the finger has not.
      current.grabOffset = fingerY - current.liftedMidY
    }
    current.fingerY = fingerY
    groupDrag = current
    reconcileGroupOrder()
  }

  /// Slot the lifted group after every other group whose middle its header
  /// has passed. A group spans its header and workspaces, down to the next
  /// header, so a tall one is crossed halfway down its workspaces.
  private func reconcileGroupOrder() {
    guard var current = groupDrag, !current.isSettling else { return }
    let liftedMidY = liftedCenterY(current)
    let others = current.order.filter { $0 != current.id }
    let frames = headerFrames.frames
    let passed = others.indices.filter { index in
      guard let header = frames[others[index]] else { return false }
      let next = others.indices.contains(index + 1) ? frames[others[index + 1]]?.minY : nil
      let bottom = max(header.maxY, next ?? header.maxY)
      return (header.minY + bottom) / 2 < liftedMidY
    }.count
    var order = others
    order.insert(current.id, at: min(passed, others.count))
    guard order != current.order else { return }
    current.order = order
    groupDrag = current
  }

  /// Commit the order, glide the floating header onto its slot, then let
  /// its group expand again.
  private func endGroupDrag(in groups: [SidebarGroup]) {
    guard var current = groupDrag, !current.isSettling else { return }
    if current.order != groups.map(\.id), let index = current.order.firstIndex(of: current.id),
      let group = groups.first(where: { $0.id == current.id })
    {
      if let folder = group.folder, let id = UUID(uuidString: folder.id) {
        navigation.moveFolder(id, to: index)
      } else if let projectId = group.projectId {
        navigation.moveProject(projectId, to: index, among: groups.compactMap(\.projectId))
      }
    }
    current.isSettling = true
    current.fingerY = nil
    let settle = reduceMotion ? 0.0 : 0.22
    withAnimation(.snappy(duration: settle)) {
      groupDrag = current
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(settle))
      guard groupDrag?.id == current.id, groupDrag?.isSettling == true else { return }
      withAnimation(.snappy(duration: 0.28)) {
        groupDrag = nil
      }
    }
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
