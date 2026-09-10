import Foundation

public struct ClientNavigationRequest: Codable, Sendable {
  public struct Destination: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case tab, pane, chat }
    public var kind: Kind
    public var id: UUID

    public var workspaceDestination: WorkspaceDestination {
      switch kind {
      case .tab: .tab(id)
      case .pane: .pane(id)
      case .chat: .chat(id)
      }
    }
  }
  public var workspaceId: UUID
  public var destination: Destination?

  /// Validate against a copy before changing any native navigation state.
  public func applying(to workspace: Workspace) throws -> Workspace {
    guard workspace.id == workspaceId, !workspace.isArchived else {
      throw ClientControlError("Workspace is unavailable")
    }
    var result = workspace
    if let destination, !result.selectDestination(destination.workspaceDestination) {
      throw ClientControlError("Destination is not in this workspace")
    }
    return result
  }
}

public struct ClientControlError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct NativeClientContext: Codable, Sendable {
  public struct Pane: Codable, Sendable {
    public var id: UUID
    public var kind: String
    public var title: String
    public var sessionId: UUID?

    init(_ pane: PaneDescriptorState) {
      id = pane.id
      kind = pane.kind.rawValue
      title = pane.name
      sessionId = pane.kind == .chat ? pane.chatSessionId : nil
    }
  }
  public struct Tab: Codable, Sendable {
    public var id: UUID
    public var panes: [Pane]
  }
  public struct Surface: Codable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var tabId: UUID
    public var paneId: UUID?
    public var sessionId: UUID?
    public var tabs: [Tab]
    public var bottomPanes: [Pane]
    public var bottomPaneId: UUID?
  }
  public var isActive: Bool
  public var workspaceId: UUID?
  public var workspaces: [Surface]

  public static func capture(
    repository: any WorkspaceRepository,
    serverId: String,
    workspaceId: UUID?,
    isActive: Bool
  ) -> Self {
    let surfaces = repository.loadAll().filter { $0.serverId == serverId && !$0.isArchived }
    return Self(
      isActive: isActive,
      workspaceId: surfaces.contains(where: { $0.id == workspaceId }) ? workspaceId : nil,
      workspaces: surfaces.map { workspace in
        let tab = workspace.selectedCenterTab
        let pane = tab.flatMap { $0.root.group(id: $0.activeLeafId)?.selectedPane }
        return Surface(
          id: workspace.id, projectId: workspace.projectId, name: workspace.name,
          tabId: workspace.selectedCenterTabId, paneId: pane?.id,
          sessionId: pane?.kind == .chat ? pane?.chatSessionId : nil,
          tabs: workspace.centerTabs.map { tab in
            Tab(id: tab.id, panes: tab.root.allGroups.flatMap { $0.state.panes.map(Pane.init) })
          },
          bottomPanes: workspace.bottomGroup.panes.map(Pane.init),
          bottomPaneId: workspace.bottomGroup.isVisible ? workspace.bottomGroup.selectedPaneId : nil
        )
      }
    )
  }
}
