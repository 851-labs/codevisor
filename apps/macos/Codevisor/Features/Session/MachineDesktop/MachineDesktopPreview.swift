import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopPreview: View {
  let session: MachineDesktopSession
  let isStreaming: Bool
  let onOpen: () -> Void
  @State private var isHovered = false

  var body: some View {
    if let viewer = session.preview.store {
      MachineDesktopCard(
        viewer: viewer, machineName: session.preview.machineName, isHovered: isHovered, onOpen: onOpen,
        onRetry: { viewer.send(.retryButtonTapped) }
      )
      .onHover { isHovered = $0 }
      .background {
        if isStreaming {
          ScreenSharingOnScreen { session.preview.onScreenChanged($0) }
        }
      }
    }
  }
}
