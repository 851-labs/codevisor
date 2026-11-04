import Foundation

extension Workspace {
  public func isMainChatPane(_ pane: PaneDescriptorState) -> Bool {
    pane.kind == .chat && pane.chatSessionId != nil && pane.chatSessionId == mainSessionId
  }

  public func holdsMainChat(_ tab: WorkspaceTab) -> Bool {
    tab.root.allGroups.contains { $0.state.panes.contains(where: isMainChatPane) }
  }

  public var mainFirstChatSessionIds: [UUID] {
    let panes = chatSessionIds
    guard let mainSessionId else { return panes }
    return [mainSessionId] + panes.filter { $0 != mainSessionId }
  }

  public func title(ofChat session: ChatSession) -> String {
    sharesName(with: session) ? name : session.title
  }

  private func sharesName(with session: ChatSession) -> Bool {
    botId == nil && session.id == mainSessionId
  }
}
