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
  /// A workspace's page, as the root of an iPhone Duo's detail column.
  case page(UUID)
  /// A folder's page, likewise.
  case folder(UUID)
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
/// compact `NavigationStack`: workspace pages, as deep as they nest, then a
/// tab. On a split layout it is at most the selected workspace's page and
/// its open tab -- `[.agent(W)]` or `[.agent(W), .workspace(W, …)]` -- or
/// New Chat. Keeping one value means folding and unfolding only slices it.
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
    case .agent, .folder, .workspace: false
    }
  }

  /// The page name reported to agent client control.
  public var clientPage: String {
    switch selection {
    case .none: "home"
    case .newChat: "new_chat"
    case .agent, .workspace: "workspace"
    case .folder: "folder"
    }
  }

  /// The workspace currently presented, if the route is one.
  public var presentedWorkspace: (serverId: String, workspaceId: UUID, anchorSessionId: UUID?)? {
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _, _, _) = selection else {
      return nil
    }
    return (serverId, workspaceId, anchorSessionId)
  }

  /// The workspace whose page or tab is on screen: the sidebar's selection
  /// on a split.
  public var selectedWorkspace: (serverId: String, workspaceId: UUID)? {
    selection?.workspace
  }

  /// A split's workspace page: the first entry, when it is one.
  public var splitPage: HomeRoute? {
    guard case .agent = path.first else { return nil }
    return path.first
  }

  /// A split's open tab: the last entry, when it is one.
  public var splitTab: HomeRoute? {
    guard case .workspace = selection else { return nil }
    return selection
  }

  // MARK: Mutations

  /// Opening a route pushes on a stack. On a split it becomes the
  /// selection: a page alone, or a tab with its workspace's page.
  public mutating func open(_ route: HomeRoute, mode: HomeLayoutMode) {
    switch mode {
    case .stack: path.append(route)
    case .split: select(route)
    }
  }

  /// Opens a tab through its workspace's page, so Back from the tab lands
  /// on the page: on a stack the page is pushed beneath it unless it is
  /// already on top, and a tab of the same workspace is swapped in place.
  public mutating func openTab(_ route: HomeRoute, mode: HomeLayoutMode) {
    guard mode == .stack, let page = route.page else {
      open(route, mode: mode)
      return
    }
    if path.last == page {
      path.append(route)
    } else if case .workspace = path.last, path.last?.page == page {
      path[path.count - 1] = route
    } else {
      path.append(contentsOf: [page, route])
    }
  }

  /// Sets the split selection outright: a page alone, a tab with its
  /// workspace's page beneath, or New Chat. Nil clears to New Chat.
  public mutating func select(_ route: HomeRoute?) {
    guard let route else {
      path = []
      return
    }
    if case .workspace = route, let page = route.page {
      path = [page, route]
    } else {
      path = [route]
    }
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

  /// Swaps a tab onto the screen in place of the top route, with its
  /// workspace's page beneath it, so Back from it lands on that page. Used
  /// when a draft's first send turns New Chat into its workspace's chat.
  public mutating func replaceTop(withTab route: HomeRoute) {
    replaceTop(with: route)
    guard let page = route.page, path.count < 2 || path[path.count - 2] != page else { return }
    path.insert(page, at: path.count - 1)
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
    case let .agent(_, workspaceId):
      return .page(workspaceId)
    case let .folder(folderId):
      return .folder(folderId)
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
  /// becomes the draft page on split; a split's page and tab become the
  /// pushed page and tab on compact. Unfolding keeps the innermost page and
  /// the tab open on it, the split's whole depth.
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
        path: splitPath(from: path), dismissesNewChatSheet: false, requestsComposerFocus: false
      )
    case .stack:
      return HomeLayoutTransition(
        path: path,
        dismissesNewChatSheet: false,
        requestsComposerFocus: path.last?.isNewChat ?? false
      )
    }
  }

  /// A stack's place as a split selection: its innermost page with the tab
  /// open on it, or just its top when that is New Chat.
  private static func splitPath(from path: [HomeRoute]) -> [HomeRoute] {
    guard let top = path.last else { return [] }
    var split = HomeNavigationState()
    split.select(top)
    return split.path
  }
}
