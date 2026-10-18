import Foundation

public enum HomeLayoutMode: Equatable, Sendable {
  case stack
  case split
}

public enum HomeDetailIdentity: Hashable, Sendable {
  case draft(UUID)
  case workspace(UUID)
  case bot(UUID)
}

public struct HomeLayoutTransition: Equatable, Sendable {
  public var path: [HomeRoute]
  public var dismissesNewChatSheet: Bool
  public var requestsComposerFocus: Bool

  public init(path: [HomeRoute], dismissesNewChatSheet: Bool, requestsComposerFocus: Bool) {
    self.path = path
    self.dismissesNewChatSheet = dismissesNewChatSheet
    self.requestsComposerFocus = requestsComposerFocus
  }
}

public struct HomeNavigationState: Equatable, Sendable {
  public var path: [HomeRoute]

  public init(path: [HomeRoute] = []) {
    self.path = path
  }

  public var selection: HomeRoute? { path.last }

  public var isNewChatSelected: Bool {
    switch selection {
    case .newChat, .none: true
    case .workspace, .bot: false
    }
  }

  public var clientPage: String {
    switch selection {
    case .none: "home"
    case .newChat: "new_chat"
    case .workspace: "workspace"
    case .bot: "bot"
    }
  }

  public var presentedWorkspace: (serverId: String, workspaceId: UUID, anchorSessionId: UUID?)? {
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _, _, _) = selection else {
      return nil
    }
    return (serverId, workspaceId, anchorSessionId)
  }

  public mutating func open(_ route: HomeRoute, mode: HomeLayoutMode) {
    switch mode {
    case .stack: path.append(route)
    case .split: path = [route]
    }
  }

  public mutating func select(_ route: HomeRoute?) {
    path = route.map { [$0] } ?? []
  }

  public mutating func replaceTop(with route: HomeRoute) {
    if path.isEmpty {
      path = [route]
    } else {
      path[path.count - 1] = route
    }
  }

  public mutating func popToRoot() {
    path.removeAll()
  }

  @discardableResult
  public mutating func followPaneSelection(workspaceId: UUID, paneId: UUID) -> Bool {
    guard case let .workspace(serverId, routeWorkspaceId, anchorSessionId, _, _, _) = selection,
      routeWorkspaceId == workspaceId
    else { return false }
    let canonical = HomeRoute.workspace(
      serverId: serverId,
      workspaceId: routeWorkspaceId,
      anchorSessionId: anchorSessionId,
      preferredChatSessionId: nil,
      preferredPaneId: paneId
    )
    guard canonical != selection else { return false }
    replaceTop(with: canonical)
    return true
  }

  public func detailRoute(fallbackServerId: String?) -> HomeRoute {
    selection ?? .newChat(serverId: fallbackServerId)
  }

  public func detailIdentity(promotedDraftSessionId: UUID?, draftGeneration: UUID) -> HomeDetailIdentity {
    switch selection {
    case .none, .newChat:
      return .draft(draftGeneration)
    case let .workspace(_, workspaceId, anchorSessionId, _, _, _):
      if let promotedDraftSessionId, anchorSessionId == promotedDraftSessionId {
        return .draft(draftGeneration)
      }
      return .workspace(workspaceId)
    case let .bot(_, botId):
      return .bot(botId)
    }
  }

  public func selectedPaneId(paneIdForChat: (UUID) -> UUID?) -> UUID? {
    guard case let .workspace(_, _, anchorSessionId, preferredChatSessionId, preferredPaneId, _) = selection
    else { return nil }
    if let preferredPaneId { return preferredPaneId }
    guard let chatId = preferredChatSessionId ?? anchorSessionId else { return nil }
    return paneIdForChat(chatId)
  }

  public static func layoutTransition(
    from: HomeLayoutMode,
    to: HomeLayoutMode,
    path: [HomeRoute],
    composingSheet: Bool,
    sheetServerId: String? = nil
  ) -> HomeLayoutTransition {
    guard from != to else {
      return HomeLayoutTransition(path: path, dismissesNewChatSheet: false, requestsComposerFocus: false)
    }
    switch to {
    case .split:
      if composingSheet {
        return HomeLayoutTransition(
          path: [.newChat(serverId: sheetServerId)],
          dismissesNewChatSheet: true,
          requestsComposerFocus: true
        )
      }
      return HomeLayoutTransition(
        path: Array(path.suffix(1)), dismissesNewChatSheet: false, requestsComposerFocus: false
      )
    case .stack:
      return HomeLayoutTransition(
        path: path,
        dismissesNewChatSheet: false,
        requestsComposerFocus: path.last?.isNewChat ?? false
      )
    }
  }
}
