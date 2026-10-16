import CodevisorCore
import CodevisorUI
import SwiftUI

struct AgentStatusIndicator: View {
  let status: AgentPaneStatus
  var activityColor: Color = .secondary

  var body: some View {
    switch status {
    case .working:
      AgentActivityIndicator(color: activityColor)
    case .unread:
      UnreadBadge(color: .blue)
    case .actionRequired:
      ActionRequiredIndicator(color: .red, subject: "terminal")
    case .error:
      ErrorUnreadBadge(color: .red, subject: "terminal")
    }
  }
}
