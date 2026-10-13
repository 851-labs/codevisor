import CodevisorCore
import CodevisorUI
import SwiftUI

/// The indicators an agent's pane shows in its icon slot. Chats use working
/// and unread here (`ChatSessionLeadingIcon` draws their other states); a
/// terminal shows whichever state its program reports.
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
    case .actionRequired:
      ActionRequiredIndicator(color: theme.statusError, subject: "terminal")
    case .error:
      ErrorUnreadBadge(color: theme.statusError, subject: "terminal")
    }
  }
}
