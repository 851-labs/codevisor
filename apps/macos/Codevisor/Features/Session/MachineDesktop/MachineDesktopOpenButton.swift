import SwiftUI

struct MachineDesktopOpenButton: View {
  private static let backing = Color(nsColor: .windowBackgroundColor).opacity(0.6)

  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(Self.backing).interactive(), in: .capsule)
    .help("Open the desktop in its own window")
    .accessibilityLabel("Open Desktop")
  }
}
