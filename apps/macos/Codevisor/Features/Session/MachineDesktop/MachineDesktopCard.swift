import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopCard: View {
  private static let aspectRatio: CGFloat = 16 / 10

  let registration: MachineDesktopRegistration
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
            MachineDesktopLivePicture(endpoint: endpoint, isHovered: isHovered, onOpen: onOpen)
          }
        }
      status
    }
    .clipShape(WorkspaceInspectorCardShape.card)
    .containerValue(\.fillsWorkspaceInspectorCardRow, true)
  }

  private var preview: ScreenSharingPreview {
    switch registration {
    case .pending: .connecting
    case .registered: viewer.preview
    case .failed(let message): .failed(message)
    }
  }

  @ViewBuilder private var status: some View {
    switch preview {
    case .connecting: MachineDesktopProgress(text: "Connecting to \(machineName)…")
    case .reconnecting: MachineDesktopProgress(text: "Reconnecting to \(machineName)…")
    case .live: EmptyView()
    case .failed(let message): MachineDesktopFailure(message: message, onRetry: onRetry)
    }
  }
}
