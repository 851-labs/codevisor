import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarGroupDrag: Equatable {
  let groupID: String
  let title: String
  let systemImage: String
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  var targetIndex: Int?

  var ghostFrame: CGRect { liftedFrame.offsetBy(dx: 0, dy: translation) }
}

extension SidebarView {
  var reordersGroups: Bool { grouping != .flat }

  func machineKey(_ serverId: String) -> String {
    workspaceListing.machineKey(serverId)
  }

  func groupReorderGesture(for id: String, heading: SidebarWorkspaceGroup.Heading) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
      .onChanged { value in
        if groupDrag?.groupID != id {
          guard let frame = dragGeometry.headings[id], frame != .zero else { return }
          withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
            groupDrag = SidebarGroupDrag(
              groupID: id, title: heading.title, systemImage: heading.systemImage, liftedFrame: frame)
          }
        }
        groupDrag?.translation = value.translation.height
        retargetGroup()
      }
      .onEnded { value in
        guard groupDrag?.groupID == id else { return }
        groupDrag?.translation = value.translation.height
        retargetGroup()
        guard let finished = groupDrag else { return }
        if let target = finished.targetIndex { commitGroupMove(finished.groupID, toIndex: target) }
        withAnimation(Motion.quick(reduceMotion: reduceMotion)) { groupDrag = nil }
        holdGroupToggles()
      }
  }

  var allowsGroupToggle: Bool { groupDrag == nil && !holdsGroupToggles }

  private func holdGroupToggles() {
    holdsGroupToggles = true
    Task {
      try? await Task.sleep(for: .milliseconds(250))
      holdsGroupToggles = false
    }
  }

  func endGroupDrag(ifMissingFrom ids: [String]) {
    guard let groupDrag, !ids.contains(groupDrag.groupID) else { return }
    self.groupDrag = nil
  }

  private var headedGroups: [SidebarWorkspaceGroup] {
    workspaceGroups.filter { $0.id != SidebarWorkspaceGroup.pinnedID && $0.heading != nil }
  }

  private func groupFrames() -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for group in headedGroups {
      guard let heading = dragGeometry.headings[group.id] else { continue }
      frames[group.id] = group.items.compactMap { dragGeometry.workspaces[$0.id] }.reduce(heading) { $0.union($1) }
    }
    return frames
  }

  private func groupDropCandidates() -> [String] {
    headedGroups.map(\.id).filter { dragGeometry.headings[$0] != nil }
  }

  private func retargetGroup() {
    guard let current = groupDrag else { return }
    let order = groupDropCandidates()
    guard
      let index = ListReorder.destinationIndex(
        of: current.groupID, in: order, frames: groupFrames(), midY: current.ghostFrame.midY)
    else { return }
    let target = order.firstIndex(of: current.groupID) == index ? nil : index
    guard target != current.targetIndex else { return }
    groupDrag?.targetIndex = target
  }

  private func commitGroupMove(_ groupID: String, toIndex index: Int) {
    let byID = Dictionary(uniqueKeysWithValues: headedGroups.map { ($0.id, $0) })
    guard let key = byID[groupID].map(orderKey) else { return }
    let shown = groupDropCandidates().compactMap { byID[$0].map(orderKey) }
    switch grouping {
    case .machine: machineOrder = SidebarWorkspaceGroup.savedOrder(machineOrder, moving: key, to: index, among: shown)
    case .project: projectOrder = SidebarWorkspaceGroup.savedOrder(projectOrder, moving: key, to: index, among: shown)
    case .flat: break
    }
  }

  private func orderKey(_ group: SidebarWorkspaceGroup) -> String {
    grouping == .project ? SidebarWorkspaceGroup.projectKey(group) : machineKey(group.items[0].serverId)
  }

  @ViewBuilder
  var groupReorderOverlay: some View {
    if let groupDrag {
      ZStack(alignment: .topLeading) {
        let frame = groupDrag.ghostFrame
        HStack(spacing: 7) {
          Image(systemName: groupDrag.systemImage)
            .font(.system(size: SidebarRowIcon.size, weight: SidebarRowIcon.weight))
            .foregroundStyle(.secondary)
            .frame(width: 18)
          Text(groupDrag.title)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: frame.width, height: frame.height)
        .sidebarDragLift()
        .position(x: frame.midX, y: frame.midY)
        if let line = groupInsertionLine(for: groupDrag) {
          SidebarInsertionLine()
            .frame(width: line.width, height: SidebarInsertionLine.height)
            .position(x: line.midX, y: line.minY)
        }
      }
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  private func groupInsertionLine(for drag: SidebarGroupDrag) -> CGRect? {
    guard let index = drag.targetIndex else { return nil }
    let frames = groupFrames()
    let others = groupDropCandidates()
      .filter { $0 != drag.groupID }
      .compactMap { frames[$0] }
    return SidebarInsertionLine.frame(at: index, among: others)
  }
}
