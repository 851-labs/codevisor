import CodevisorCore
import CodevisorUI
import SwiftUI

struct AgentStatusIndicator: View {
  let status: AgentPaneStatus
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
