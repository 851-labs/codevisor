import CodevisorCore
import CodevisorUI
import SwiftUI

/// Renders one workspace tab's split tree on the unfolded iPhone Duo display.
/// Two leaves are handed to the system's arrangement view, which places one
/// pane per half when the device is folded like a book or a laptop and tiles
/// them by aspect otherwise. Deeper trees (and older systems) use the shared
/// layout snapshot with draggable dividers, as macOS does.
struct WorkspaceSplitContainerView<Leaf: View>: View {
  let tab: WorkspaceTab
  let paneState: PaneGroupState
  @ViewBuilder let leaf: (UUID, PaneDescriptorState) -> Leaf
  let onActivate: (PaneDescriptorState) -> Void
  let onTreeChanged: (SplitNode) -> Void

  /// The narrowest a pane may render beside another on a phone-class
  /// display; below the desktop floor so a book fold still fits two.
  static var minChildWidth: CGFloat { 240 }
  static var minChildHeight: CGFloat { 200 }

  /// The tree while a divider is being dragged; persisted on release.
  @State private var liveRoot: SplitNode?
  @State private var dragStartFractions: [Double]?

  private var root: SplitNode { liveRoot ?? tab.root }

  var body: some View {
    if #available(iOS 27.1, *), let pair = twoLeafPair {
      ArrangementView {
        leafView(pair.first)
      } secondary: {
        leafView(pair.second)
      }
      // Both axes: the system splits by aspect and re-orients to keep one
      // pane per half as the device folds.
      .arrangementViewStyle(.split.axes([.horizontal, .vertical]))
    } else {
      snapshotLayout
    }
  }

  /// Exactly two leaves under one split — the arrangement view's shape.
  private var twoLeafPair: (first: UUID, second: UUID)? {
    guard case let .split(_, children) = tab.root, children.count == 2,
      let first = children[0].node.directLeafID,
      let second = children[1].node.directLeafID
    else { return nil }
    return (first, second)
  }

  private var snapshotLayout: some View {
    GeometryReader { proxy in
      let snapshot = WorkspaceSplitLayoutSnapshot.make(
        node: root,
        size: proxy.size,
        minChildWidth: Self.minChildWidth,
        minChildHeight: Self.minChildHeight
      )
      ZStack(alignment: .topLeading) {
        ForEach(snapshot.leaves) { item in
          leafView(item.id)
            .frame(width: item.frame.width, height: item.frame.height)
            .position(x: item.frame.midX, y: item.frame.midY)
        }
        ForEach(snapshot.dividers) { divider in
          WorkspaceSplitDividerView(
            divider: divider,
            onChanged: { resize(divider, translation: $0) },
            onEnded: finishResize
          )
        }
      }
    }
  }

  @ViewBuilder
  private func leafView(_ leafId: UUID) -> some View {
    if let pane = PaneLayoutProjection.pane(inLeaf: leafId, of: tab, state: paneState) {
      let isActive = leafId == tab.activeLeafId
      leaf(leafId, pane)
        .clipped()
        .overlay(alignment: .top) {
          Rectangle()
            .fill(Color.accentColor.opacity(0.6))
            .frame(height: 2)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // Simultaneous so the pane's own controls, and UIKit-backed
        // surfaces, keep every touch; this only records the active leaf.
        .simultaneousGesture(TapGesture().onEnded { onActivate(pane) })
        .accessibilityAddTraits(isActive ? .isSelected : [])
    } else {
      Color.clear
    }
  }

  private func resize(_ divider: WorkspaceSplitLayoutSnapshot.Divider, translation: CGFloat) {
    guard divider.contentLength > 0 else { return }
    let start = dragStartFractions ?? divider.sourceFractions
    dragStartFractions = start
    let index = divider.childIndex
    guard start.indices.contains(index + 1) else { return }
    let minLength = divider.isHorizontal ? Self.minChildWidth : Self.minChildHeight
    let minFraction = Double(minLength / divider.contentLength)
    var delta = Double(translation / divider.contentLength)
    delta = max(delta, minFraction - start[index])
    delta = min(delta, start[index + 1] - minFraction)
    var fractions = start
    fractions[index] = start[index] + delta
    fractions[index + 1] = start[index + 1] - delta
    liveRoot = root.replacingSplitFractions(at: divider.branchPath, with: fractions)
  }

  private func finishResize() {
    guard let liveRoot else { return }
    dragStartFractions = nil
    self.liveRoot = nil
    onTreeChanged(liveRoot)
  }
}

/// A hairline between two leaves with a wider, invisible grip for dragging.
struct WorkspaceSplitDividerView: View {
  let divider: WorkspaceSplitLayoutSnapshot.Divider
  let onChanged: (CGFloat) -> Void
  let onEnded: () -> Void

  var body: some View {
    Rectangle()
      .fill(Color(uiColor: .separator))
      .frame(width: divider.lineFrame.width, height: divider.lineFrame.height)
      .position(x: divider.lineFrame.midX, y: divider.lineFrame.midY)
      .allowsHitTesting(false)
    Color.clear
      .contentShape(Rectangle())
      .frame(width: divider.gripFrame.width, height: divider.gripFrame.height)
      .position(x: divider.gripFrame.midX, y: divider.gripFrame.midY)
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            onChanged(divider.isHorizontal ? value.translation.width : value.translation.height)
          }
          .onEnded { _ in onEnded() }
      )
      .accessibilityLabel("Resize panes")
  }
}
