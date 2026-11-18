import AppKit
import CodevisorCoreMac
import SwiftUI

struct MachineDesktopLivePicture: View {
  private static let cardGrey = NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return NSColor(white: isDark ? 0.16 : 0.9, alpha: 1)
  }

  let pane: ScreenSharingPane
  let endpoint: ScreenSharingViewerEndpoint
  let aspectRatio: CGFloat
  let isHovered: Bool
  let onOpen: () -> Void

  var body: some View {
    Color.clear
      .overlay { picture }
      .overlay { openButton }
      .contentShape(WorkspaceInspectorCardShape.card)
      .onTapGesture(perform: onOpen)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Desktop")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, onOpen)
  }

  private var picture: some View {
    ScreenSharingNativeView(pane: pane, letterbox: Self.cardGrey)
      .id(endpoint.id)
      .aspectRatio(aspectRatio, contentMode: .fit)
      .clipShape(WorkspaceInspectorCardShape.card)
      .allowsHitTesting(false)
  }

  private var openButton: some View {
    MachineDesktopOpenButton(action: onOpen)
      .opacity(isHovered ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}
