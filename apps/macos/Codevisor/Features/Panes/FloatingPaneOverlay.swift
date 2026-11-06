import CodevisorCore
import CodevisorCoreMac
import SwiftUI

struct FloatingPaneOverlay: View {
  let panes: [FloatingPane]
  let group: (UUID) -> PaneGroupModel
  let title: (PaneDescriptorState) -> String
  let actions: (UUID) -> FloatingPaneActions

  private static let coordinateSpace = "floating-panes"

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Color.clear.allowsHitTesting(false)
        ForEach(Array(panes.enumerated()), id: \.element.leafId) { index, pane in
          card(pane, index: index, container: geometry.size)
        }
      }
      .coordinateSpace(name: Self.coordinateSpace)
    }
  }

  private func card(_ pane: FloatingPane, index: Int, container: CGSize) -> some View {
    let model = group(pane.leafId)
    let actions = actions(pane.leafId)
    let placed = pane.frame ?? FloatingPaneGeometry.defaultFrame(index: index, container: container)
    return FloatingPaneCard(
      group: model,
      title: model.state.selectedPane.map(title) ?? "New Tab",
      frame: FloatingPaneGeometry.clamped(placed, container: container),
      container: container,
      coordinateSpace: Self.coordinateSpace,
      actions: actions
    )
    .onChange(of: container, initial: true) {
      guard pane.frame == nil, FloatingPaneGeometry.fits(in: container) else { return }
      actions.move(placed)
    }
  }
}
