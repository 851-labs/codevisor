import CodevisorCoreMac
import SwiftUI

struct MachineDesktopLivePicture: View {
  let endpoint: ScreenSharingViewerEndpoint
  let isHovered: Bool
  let onOpen: () -> Void

  var body: some View {
    ScreenSharingMirrorHost(endpoint: endpoint, letterbox: .clear)
      .id(endpoint.id)
      .allowsHitTesting(false)
      .overlay { openButton }
      .contentShape(WorkspaceInspectorCardShape.card)
      .onTapGesture(perform: onOpen)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Desktop")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, onOpen)
  }

  private var openButton: some View {
    MachineDesktopOpenButton(action: onOpen)
      .opacity(isHovered ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}
