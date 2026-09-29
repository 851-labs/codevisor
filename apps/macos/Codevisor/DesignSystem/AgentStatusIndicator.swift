import CodevisorCore
import CodevisorUI
import SwiftUI

/// The working and unread indicators an agent's pane shows in its icon
/// slot. Chats show both; a CLI running in a terminal shows only working.
struct AgentStatusIndicator: View {
  let status: AgentPaneStatus
  /// The working glyph's tint; see `ChatSessionLeadingIcon.activityColor`.
  var activityColor: Color = .secondary

  @Environment(\.theme) private var theme

  var body: some View {
    switch status {
    case .working:
      AgentActivityIndicator(color: activityColor)
    case .unread:
      UnreadBadge(color: theme.isSystem ? .blue : theme.accent)
    }
  }
}
