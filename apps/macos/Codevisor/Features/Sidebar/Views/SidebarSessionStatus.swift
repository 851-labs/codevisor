import CodevisorCore
import SwiftUI

/// The trailing hover affordance on a chat/workspace row: an archive button,
/// suppressed while the row is badged with an unread error.
struct SidebarSessionStatus: View {
  let session: ChatSession
  let store: SessionStore?
  let isHovered: Bool
  let onArchive: () -> Void

  var body: some View {
    if store?.hasUnreadError(session) != true, isHovered {
      Button {
        onArchive()
      } label: {
        Image(systemName: "archivebox")
          .font(.caption2)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Archive chat")
      .accessibilityLabel("Archive \(session.title)")
      .frame(width: 24, height: 14, alignment: .trailing)
    }
  }
}
