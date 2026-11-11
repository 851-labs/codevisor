import Foundation

extension Workspace {
  public func isMainChatPane(_ pane: PaneDescriptorState) -> Bool {
    pane.kind == .chat && pane.chatSessionId != nil && pane.chatSessionId == mainSessionId
  }

  public func holdsMainChat(_ tab: WorkspaceTab) -> Bool {
    tab.root.allGroups.contains { $0.state.panes.contains(where: isMainChatPane) }
  }

  public var mainTab: WorkspaceTab {
    centerTabs.first(where: holdsMainChat) ?? centerTabs[0]
  }

  public var sideTabs: [WorkspaceTab] {
    let mainId = mainTab.id
    return centerTabs.filter { $0.id != mainId }
  }

  public var mainFirstTabs: [WorkspaceTab] {
    [mainTab] + sideTabs
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
    session.id == mainSessionId
  }
}
