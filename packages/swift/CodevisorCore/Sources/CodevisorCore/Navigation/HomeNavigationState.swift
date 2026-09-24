import Foundation

/// Which container Home renders in. `.stack` is the compact-width
/// `NavigationStack`; `.split` is the regular-width `NavigationSplitView`
/// used on the unfolded iPhone Duo display. Chosen from the horizontal size
/// class, never from orientation.
public enum HomeLayoutMode: Equatable, Sendable {
  case stack
  case split
}

/// The SwiftUI identity of the split view's detail column. A draft keeps the
/// `.draft` identity through its first send so the composer, transcript and
/// first responder are not remounted when the route becomes a workspace.
public enum HomeDetailIdentity: Hashable, Sendable {
  /// A draft, keyed by a generation Home bumps each time it enters New
  /// Chat afresh, so a new draft after a promotion still remounts.
  case draft(UUID)
  case workspace(UUID)
}

/// What Home must do when the size class changes containers.
public struct HomeLayoutTransition: Equatable, Sendable {
  public var path: [HomeRoute]
  /// A composing New Chat sheet cannot survive the swap to a split view; its
  /// draft continues as the detail page instead.
  public var dismissesNewChatSheet: Bool
  /// The draft page should take keyboard focus once mounted.
  public var requestsComposerFocus: Bool

  public init(path: [HomeRoute], dismissesNewChatSheet: Bool, requestsComposerFocus: Bool) {
    self.path = path
    self.dismissesNewChatSheet = dismissesNewChatSheet
    self.requestsComposerFocus = requestsComposerFocus
  }
}

/// Home's single navigation truth for both containers. `path` binds to the
/// compact `NavigationStack`; on a split layout `path.last` is the detail
/// selection. Keeping one value means folding and unfolding never has to
/// translate between two models.
public struct HomeNavigationState: Equatable, Sendable {
  public var path: [HomeRoute]

  public init(path: [HomeRoute] = []) {
    self.path = path
  }

  /// The route on screen: the top of the stack, or the split detail.
  public var selection: HomeRoute? { path.last }

  /// New Chat is selected when it is the route or when nothing is, matching
  /// the macOS sidebar where an empty selection reads as New Chat.
  public var isNewChatSelected: Bool {
    switch selection {
    case .newChat, .none: true
    case .workspace: false
    }
  }

  /// The page name reported to agent client control.
  public var clientPage: String {
    switch selection {
    case .none: "home"
    case .newChat: "new_chat"
    case .workspace: "workspace"
    }
  }

  /// The workspace currently presented, if the route is one.
  public var presentedWorkspace: (serverId: String, workspaceId: UUID, anchorSessionId: UUID?)? {
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _, _, _) = selection else {
      return nil
    }
    return (serverId, workspaceId, anchorSessionId)
  }

  // MARK: Mutations

  /// Opening a route pushes on a stack and replaces the detail on a split.
  public mutating func open(_ route: HomeRoute, mode: HomeLayoutMode) {
    switch mode {
    case .stack: path.append(route)
    case .split: path = [route]
    }
  }

  /// Sets the split selection outright. Nil clears to New Chat.
  public mutating func select(_ route: HomeRoute?) {
    path = route.map { [$0] } ?? []
  }

  /// Swaps the route on screen without changing depth. Used when a draft's
  /// first send turns New Chat into its workspace, and when a server refresh
  /// retargets the presented chat.
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

  /// Mirrors a mounted workspace's own pane selection back into the route.
  ///
  /// The route's preferred chat/pane is a request to show something, not a
  /// record of what is shown — the workspace's persisted selection is that.
  /// New Tab, a pane conversion, a close, and agent client-control all move
  /// that selection without going through Home. On a split layout the detail
  /// screen is re-targeted rather than remounted, so it only switches panes
  /// when the route *changes*; a route still naming the pane a sidebar tap
  /// last asked for therefore makes re-selecting that row a silent no-op, and
  /// makes a later remount reopen a pane the workspace has moved off.
  ///
  /// Following the selection keeps the route canonical — one preferred pane,
  /// no preferred chat — so the next tap on any other row is a real change.
  /// Returns whether the route moved, so callers can skip redundant writes.
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

  // MARK: Split detail

  /// The route the detail column renders. An empty selection is New Chat.
  public func detailRoute(fallbackServerId: String?) -> HomeRoute {
    selection ?? .newChat(serverId: fallbackServerId)
  }

  /// The detail's SwiftUI identity. The workspace a draft was promoted into
  /// keeps the draft's identity so the screen transitions in place.
  public func detailIdentity(promotedDraftSessionId: UUID?, draftGeneration: UUID) -> HomeDetailIdentity {
    switch selection {
    case .none, .newChat:
      return .draft(draftGeneration)
    case let .workspace(_, workspaceId, anchorSessionId, _, _, _):
      if let promotedDraftSessionId, anchorSessionId == promotedDraftSessionId {
        return .draft(draftGeneration)
      }
      return .workspace(workspaceId)
    }
  }

  /// The sidebar row to highlight for the current selection. Chat rows are
  /// keyed by pane id, so the caller resolves a chat session to its pane.
  public func selectedPaneId(paneIdForChat: (UUID) -> UUID?) -> UUID? {
    guard case let .workspace(_, _, anchorSessionId, preferredChatSessionId, preferredPaneId, _) = selection
    else { return nil }
    if let preferredPaneId { return preferredPaneId }
    guard let chatId = preferredChatSessionId ?? anchorSessionId else { return nil }
    return paneIdForChat(chatId)
  }

  // MARK: Layout transitions

  /// What changes when the container swaps. A composing sheet on compact
  /// becomes the draft page on split; a split detail becomes the pushed
  /// route on compact. A stack deeper than one entry keeps only its top on
  /// split, since a split has no depth.
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
