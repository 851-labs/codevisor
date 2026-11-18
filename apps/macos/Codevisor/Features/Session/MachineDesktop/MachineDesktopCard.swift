import CodevisorCoreMac
import ComposableArchitecture
import ScreenSharingConnection
import SwiftUI

struct MachineDesktopCard: View {
  private static let reshape = Animation.smooth(duration: 0.3)

  let pane: ScreenSharingPane
  let viewer: StoreOf<ScreenSharingViewer>
  let machineName: String
  let isHovered: Bool
  let onOpen: () -> Void
  let onRetry: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var settledShape: ScreenSharingPreviewShape?

  var body: some View {
    ZStack {
      Color.clear
        .aspectRatio(shape.card, contentMode: .fit)
        .overlay {
          if case .live(let endpoint) = preview {
            MachineDesktopLivePicture(
              pane: pane, endpoint: endpoint, aspectRatio: viewer.previewShape.picture, isHovered: isHovered,
              onOpen: onOpen)
          }
        }
      status
    }
    .clipShape(WorkspaceInspectorCardShape.card)
    .containerValue(\.fillsWorkspaceInspectorCardRow, true)
    .onChange(of: viewer.previewShape, initial: true) { _, shape in settle(on: shape) }
  }

  private var preview: ScreenSharingPreview { viewer.preview }

  private var shape: ScreenSharingPreviewShape { settledShape ?? viewer.previewShape }

  private func settle(on shape: ScreenSharingPreviewShape) {
    let isFirst = settledShape == nil
    withAnimation(isFirst || reduceMotion ? nil : Self.reshape) { settledShape = shape }
  }

  @ViewBuilder private var status: some View {
    switch preview {
    case .connecting: progress("Connecting to \(machineName)…")
    case .reconnecting: progress("Reconnecting to \(machineName)…")
    case .live: EmptyView()
    case .failed(let sentence, let action):
      ScreenSharingStatusView(content: .failure(sentence: sentence, action: action), size: .card, onAction: act)
    }
  }

  private func act(_ action: ScreenSharingFailureAction) {
    if action == .viewHere {
      onOpen()
    } else {
      onRetry()
    }
  }

  private func progress(_ title: String) -> some View {
    ScreenSharingStatusView(content: .progress(title: title, details: []), size: .card) { _ in }
  }
}
