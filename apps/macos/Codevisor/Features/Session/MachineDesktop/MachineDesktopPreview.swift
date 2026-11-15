import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopPreview: View {
  let machine: CodevisorMachine
  let workspaceId: UUID
  let isStreaming: Bool
  let onOpen: () -> Void
  @State private var pane: ScreenSharingPane?
  @State private var isHovered = false

  var body: some View {
    ZStack {
      if let pane, let viewer = pane.store {
        MachineDesktopCard(
          viewer: viewer, machineName: pane.machineName, isHovered: isHovered, onOpen: onOpen,
          onRetry: { viewer.send(.retryButtonTapped) }
        )
        .onHover { isHovered = $0 }
        .background {
          if isStreaming {
            ScreenSharingOnScreen { pane.onScreenChanged($0) }
          }
        }
      }
    }
    .onAppear(perform: attach)
    .onDisappear(perform: detach)
    .onChange(of: workspaceId) { pane?.shown(inWorkspace: workspaceId) }
  }

  private func attach() {
    guard pane == nil else { return }

    pane = MachineDesktops.shared.pane(on: machine, role: .watcher, shownInWorkspace: workspaceId)
  }

  private func detach() {
    pane?.detach()
    pane = nil
  }
}
