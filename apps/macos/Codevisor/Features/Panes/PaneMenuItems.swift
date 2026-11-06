import CodevisorCore
import SwiftUI

struct PaneMenuItems: View {
  let pane: PaneDescriptorState?
  let sessionStore: SessionStore?

  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    if let session = Self.chatSession(of: pane, in: environment.projectList) {
      ChatSessionUnreadMenuItem(session: session, store: sessionStore)
    }
  }

  static func chatSession(of pane: PaneDescriptorState?, in projectList: ProjectListModel) -> ChatSession? {
    guard pane?.kind == .chat || pane?.kind == .childAgent, let sessionId = pane?.chatSessionId else { return nil }
    return projectList.sessions.first(where: { $0.id == sessionId })
  }
}
