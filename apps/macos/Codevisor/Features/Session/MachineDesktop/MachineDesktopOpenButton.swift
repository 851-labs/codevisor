import SwiftUI

struct MachineDesktopOpenButton: View {
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
    .glassEffect(.regular.interactive(), in: .capsule)
    .help("Open the desktop in its own window")
    .accessibilityLabel("Open Desktop")
  }
}
