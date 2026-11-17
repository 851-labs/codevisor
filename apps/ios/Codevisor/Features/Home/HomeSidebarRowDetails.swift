import CodevisorCore
import CodevisorUI

struct HomeSidebarRowDetails: Equatable {
  let title: String
  let serverId: String
  var subtitle: String? = nil
  var rowStatus: SidebarRowStatus? = nil
  var showsStatusLabel = false
  var machine: HomeSidebarRowMachine? = nil
  var pullRequest: ServerGitPullRequest? = nil
  var leadingRow: HomeSidebarTabRow? = nil
  var attention = HomeSessionStatus.idle
  var isArchived = false

  var statusLabel: SidebarRowStatus? { showsStatusLabel ? rowStatus : nil }

  var leadingStatus: SidebarRowStatus? {
    guard let rowStatus, rowStatus.replacesLeadingIcon(isUnread: leadingRow?.status == .unread) else { return nil }
    return rowStatus
  }

  var accessibilityLabel: String {
    [
      title, attentionLabel, rowStatus?.title, subtitle,
      pullRequest.map { "pull request \($0.number)" },
      machine.map { "on \($0.name)" },
    ].compactMap { $0 }.joined(separator: ", ")
  }

  private var attentionLabel: String? {
    switch attention {
    case .error: "error"
    case .actionRequired: "needs attention"
    case .unread: "unread"
    case .inProgress: "working"
    case .idle: nil
    }
  }
}
