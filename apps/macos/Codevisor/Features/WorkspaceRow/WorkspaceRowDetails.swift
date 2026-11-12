import CodevisorClient
import CodevisorCore
import CodevisorUI

struct WorkspaceRowDetails {
  let name: String
  var subtitle: String? = nil
  var status: SidebarRowStatus? = nil
  var showsStatusLabel = false
  let icon: SidebarWorkspaceIcon
  var pullRequest: ServerGitPullRequest? = nil
  var machine: SidebarRowMachine? = nil

  var title: String { SidebarWorkspaceRowLabel.title(for: name) }

  var unreadChat: ChatSession? {
    guard case let .chat(session, isQuiet: false) = icon else { return nil }
    return session
  }
}
