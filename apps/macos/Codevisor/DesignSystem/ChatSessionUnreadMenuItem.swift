import CodevisorCore
import CodevisorUI
import SwiftUI

struct ChatSessionUnreadMenuItem: View {
  let session: ChatSession

  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    UnreadMenuItem(isUnread: session.isUnread, setUnread: setUnread)
  }

  private func setUnread(_ isUnread: Bool) {
    let projectList = environment.projectList
    if isUnread {
      projectList.markSessionUnread(session.id, serverId: session.serverId)
    } else {
      projectList.markSessionRead(session.id, serverId: session.serverId)
    }
  }
}
