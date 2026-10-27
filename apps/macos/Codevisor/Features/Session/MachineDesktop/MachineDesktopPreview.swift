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
        session.pane.makeView()
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
    Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
      .font(.callout.weight(.medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(.black.opacity(0.75), in: .capsule)
      .opacity(isHovered || !isStreaming ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}
