import SwiftUI

struct SidebarGroupNewChatButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "square.and.pencil")
        .font(.callout.weight(.semibold))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("New chat in \(title)")
    .accessibilityLabel("New chat in \(title)")
    .accessibilityHidden(true)
  }
}
