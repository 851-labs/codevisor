import CodevisorCoreMac
import ComposableArchitecture
import ScreenSharingConnection
import SwiftUI

struct MachineDesktopCard: View {
  private static let aspectRatio: CGFloat = 16 / 10

  let pane: ScreenSharingPane
  let viewer: StoreOf<ScreenSharingViewer>
  let machineName: String
  let isHovered: Bool
  let onOpen: () -> Void
  let onRetry: () -> Void

  var body: some View {
    ZStack {
      Color.clear
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .overlay {
          if case .live(let endpoint) = preview {
            MachineDesktopLivePicture(pane: pane, endpoint: endpoint, isHovered: isHovered, onOpen: onOpen)
          }
        }
      status
    }
    .clipShape(WorkspaceInspectorCardShape.card)
    .containerValue(\.fillsWorkspaceInspectorCardRow, true)
  }

  private var preview: ScreenSharingPreview { viewer.preview }

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
