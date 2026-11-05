import SwiftUI

struct SidebarRowHoverButton: View {
  let systemImage: String
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
        .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHidden(true)
  }
}
