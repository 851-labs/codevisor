import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI

struct WorkspaceSplitView: View {
  let node: SplitNode
  let activeLeafId: UUID?
  let groupModel: (UUID) -> PaneGroupModel
  let paneTitle: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onSplitLeaf: (UUID, SplitEdge) -> Void
  let onCloseLeaf: (UUID) -> Void
  var onFloatLeaf: ((UUID) -> Void)? = nil
  var openingSplit: WorkspaceSplitOpening? = nil
  var onOpeningFinished: ((WorkspaceSplitOpening) -> Void)? = nil
  let onTreeChanged: (SplitNode) -> Void
  var onLiveTreeChanged: ((SplitNode) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.transcriptTopChromeHeight) private var transcriptTopChromeHeight
  @State private var activeDividerDrag: ActiveDividerDrag?

  var body: some View {
    GeometryReader { geometry in
      let snapshot = WorkspaceSplitLayoutSnapshot.make(
        node: node,
        size: geometry.size
      )
      let hasMultipleLeaves = snapshot.leaves.count > 1
      let clip = WorkspaceSplitClip(extendsAboveTop: extendsChatAboveTop(snapshot))

      ZStack(alignment: .topLeading) {
        ForEach(snapshot.leaves) { leaf in
          let opening = openingSplit?.leafId == leaf.id ? openingSplit : nil
          SplitLeafView(
            leafId: leaf.id,
            isInactive: opening == nil && hasMultipleLeaves && activeLeafId != nil
              && leaf.id != activeLeafId,
            showsHeader: hasMultipleLeaves,
            openingEdge: opening?.edge,
            groupModel: groupModel,
            paneTitle: paneTitle,
            sessionStore: sessionStore,
            dragCoordinator: dragCoordinator,
            onSplit: { edge in onSplitLeaf(leaf.id, edge) },
            onClose: { onCloseLeaf(leaf.id) },
            onFloat: onFloatLeaf.map { float in { float(leaf.id) } }
          )
          .frame(
            width: max(0, leaf.frame.width),
            height: max(0, leaf.frame.height)
          )
          .clipShape(clip)
          .position(x: leaf.frame.midX, y: leaf.frame.midY)
          .transition(openingTransition(for: opening))
        }

        ForEach(snapshot.dividers) { divider in
          if !isOpeningDivider(divider) {
            Color.separatorColor
              .frame(
                width: divider.lineFrame.width,
                height: divider.lineFrame.height
              )
              .position(
                x: divider.lineFrame.midX,
                y: divider.lineFrame.midY
              )

            dividerGrip(divider)
              .frame(
                width: divider.gripFrame.width,
                height: divider.gripFrame.height
              )
              .position(
                x: divider.gripFrame.midX,
                y: divider.gripFrame.midY
              )
          }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipShape(clip)
    }
    .overlay { dragGhostOverlay }
    .task(id: openingSplit?.id) {
      guard let openingSplit else { return }
      if !reduceMotion {
        try? await Task.sleep(for: .seconds(Motion.splitDuration))
      }
      guard !Task.isCancelled, self.openingSplit == openingSplit else { return }
      onOpeningFinished?(openingSplit)
    }
  }

  private func extendsChatAboveTop(_ snapshot: WorkspaceSplitLayoutSnapshot) -> Bool {
    guard transcriptTopChromeHeight > 0, snapshot.leaves.count == 1, let leaf = snapshot.leaves.first else {
      return false
    }
    return groupModel(leaf.id).state.selectedPane?.kind == .chat
  }

  private func openingTransition(for opening: WorkspaceSplitOpening?) -> AnyTransition {
    guard let opening, !reduceMotion else { return .identity }
    return .scale(scale: 0.001, anchor: opening.edge.revealAnchor)
  }

  private func isOpeningDivider(_ divider: WorkspaceSplitLayoutSnapshot.Divider) -> Bool {
    guard let openingSplit else { return false }
    switch openingSplit.edge {
    case .leading, .top:
      return divider.beforeLeafID == openingSplit.leafId
    case .trailing, .bottom:
      return divider.afterLeafID == openingSplit.leafId
    }
  }

  private func dividerGrip(
    _ divider: WorkspaceSplitLayoutSnapshot.Divider
  ) -> some View {
    SplitDividerGrip(
      isHorizontal: divider.isHorizontal,
      onChanged: { translation in
        resize(divider, translation: translation)
      },
      onEnded: finishDividerResize
    )
  }

  private func resize(
    _ divider: WorkspaceSplitLayoutSnapshot.Divider,
    translation: CGFloat
  ) {
    guard divider.contentLength > 0 else { return }
    let drag: ActiveDividerDrag
    if let activeDividerDrag, activeDividerDrag.id == divider.id {
      drag = activeDividerDrag
    } else {
      drag = ActiveDividerDrag(
        id: divider.id,
        startFractions: divider.sourceFractions,
        latestTree: node
      )
    }
    let index = divider.childIndex
    guard drag.startFractions.indices.contains(index + 1) else { return }

    let minChildLength =
      divider.isHorizontal
      ? WorkspaceSplitDragCoordinator.minChildWidth
      : WorkspaceSplitDragCoordinator.minChildHeight
    let minFraction = Double(minChildLength / divider.contentLength)
    var delta = Double(translation / divider.contentLength)
    delta = max(delta, minFraction - drag.startFractions[index])
    delta = min(delta, drag.startFractions[index + 1] - minFraction)
    var updatedFractions = drag.startFractions
    updatedFractions[index] = drag.startFractions[index] + delta
    updatedFractions[index + 1] = drag.startFractions[index + 1] - delta
    let updatedTree = node.replacingSplitFractions(
      at: divider.branchPath,
      with: updatedFractions
    )
    activeDividerDrag = ActiveDividerDrag(
      id: divider.id,
      startFractions: drag.startFractions,
      latestTree: updatedTree
    )
    onLiveTreeChanged?(updatedTree)
  }

  private func finishDividerResize() {
    guard let activeDividerDrag else { return }
    self.activeDividerDrag = nil
    onTreeChanged(activeDividerDrag.latestTree)
  }

  private var dragGhostOverlay: some View {
    GeometryReader { proxy in
      if let drag = dragCoordinator?.active {
        WorkspaceSplitDragGhost(name: drag.name, kind: drag.kind)
          .position(
            x: drag.location.x - proxy.frame(in: .global).minX,
            y: drag.location.y - proxy.frame(in: .global).minY
          )
      }
    }
    .allowsHitTesting(false)
  }
}

private struct ActiveDividerDrag {
  let id: WorkspaceSplitLayoutSnapshot.DividerID
  let startFractions: [Double]
  let latestTree: SplitNode
}

private extension SplitEdge {
  var revealAnchor: UnitPoint {
    switch self {
    case .leading: .leading
    case .trailing: .trailing
    case .top: .top
    case .bottom: .bottom
    }
  }
}

private struct SplitLeafView: View {
  let leafId: UUID
  let isInactive: Bool
  let showsHeader: Bool
  let openingEdge: SplitEdge?
  let groupModel: (UUID) -> PaneGroupModel
  let paneTitle: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onSplit: (SplitEdge) -> Void
  let onClose: () -> Void
  let onFloat: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Color.clear
      if openingEdge == nil {
        leafContent
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay { inactiveSplitTint }
    .overlay { openingDivider }
    .workspaceSplitDropZone(dragCoordinator, leafId: leafId)
    .allowsHitTesting(openingEdge == nil)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: openingEdge == nil)
  }

  private func holdsMainChat(_ model: PaneGroupModel) -> Bool {
    guard let pane = model.state.selectedPane else { return false }
    return model.isWorkspaceMainChat?(pane) == true
  }

  private var leafContent: some View {
    let model = groupModel(leafId)
    return VStack(spacing: 0) {
      if showsHeader {
        SplitLeafHeader(
          pane: model.state.selectedPane,
          title: paneTitle,
          sessionStore: sessionStore,
          pluginIconClient: model.pluginIconClient,
          pluginIconCacheNamespace: model.pluginIconCacheNamespace,
          leafId: leafId,
          dragCoordinator: dragCoordinator,
          onActivate: { model.onActivated?() },
          onSplit: onSplit,
          onClose: holdsMainChat(model) ? nil : onClose,
          onFloat: holdsMainChat(model) ? nil : onFloat
        )
      }
      ZStack {
        Color.clear
        PaneGroupContent(group: model)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { PaneActivationObserver { model.onActivated?() } }
    }
  }

  @ViewBuilder
  private var openingDivider: some View {
    if let openingEdge {
      Color.separatorColor
        .frame(
          maxWidth: openingEdge == .top || openingEdge == .bottom
            ? .infinity : nil,
          maxHeight: openingEdge == .leading || openingEdge == .trailing
            ? .infinity : nil
        )
        .frame(
          width: openingEdge == .leading || openingEdge == .trailing ? 1 : nil,
          height: openingEdge == .top || openingEdge == .bottom ? 1 : nil
        )
        .frame(
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: openingEdge.dividerAlignment
        )
        .allowsHitTesting(false)
    }
  }

  private var inactiveSplitTint: some View {
    Rectangle()
      .fill(Color.windowBackgroundColor)
      .opacity(isInactive ? 0.3 : 0)
      .allowsHitTesting(false)
      .transaction { $0.animation = nil }
  }
}

private extension SplitEdge {
  var dividerAlignment: Alignment {
    switch self {
    case .leading: .trailing
    case .trailing: .leading
    case .top: .bottom
    case .bottom: .top
    }
  }
}
