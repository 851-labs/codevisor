import SwiftUI

struct MachineDesktopPreview: View {
  private static let aspectRatio: CGFloat = 16 / 10

  let session: MachineDesktopSession
  let isStreaming: Bool
  let onOpen: () -> Void
  @State private var isRegistered = false
  @State private var isHovered = false

  var body: some View {
    ZStack {
      Rectangle().fill(.quaternary)
      if isRegistered, isStreaming {
        session.preview.makeView()
          .allowsHitTesting(false)
      }
      openBadge
    }
    .aspectRatio(Self.aspectRatio, contentMode: .fit)
    .clipShape(.rect(cornerRadius: 10))
    .contentShape(.rect(cornerRadius: 10))
    .onTapGesture(perform: onOpen)
    .onHover { isHovered = $0 }
    .task { isRegistered = await session.register() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Desktop")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, onOpen)
  }

  private var openBadge: some View {
    MachineDesktopOpenButton(action: onOpen)
      .opacity(isHovered || !isStreaming ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}
