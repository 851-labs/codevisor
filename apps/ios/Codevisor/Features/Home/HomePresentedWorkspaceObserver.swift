import CodevisorCore
import SwiftUI

/// Re-decides whether the presented workspace route stays valid, on Home's
/// behalf, only when something that decision reads has changed.
///
/// The decision (`WorkspaceSyncModel.routeDisposition`) scans the fleet's
/// chats, so it never runs in a body. This view observes just the presented
/// workspace's entry and whether its anchor chat still exists, and runs the
/// decision from `onChange` -- a chat elsewhere being marked read, or another
/// workspace changing, re-renders nothing.
struct HomePresentedWorkspaceObserver: View {
  @Environment(AppEnvironment.self) private var environment
  /// The route on screen; only a workspace route is checked.
  let route: HomeRoute?
  let apply: (WorkspaceRouteDisposition) -> Void

  /// Everything the disposition depends on, as cheap comparable values.
  private struct Trigger: Equatable {
    let route: HomeRoute?
    let generation: UInt64?
    let anchorExists: Bool
  }

  var body: some View {
    Color.clear
      .onChange(of: trigger, initial: true) { _, _ in
        apply(disposition)
      }
  }

  private var trigger: Trigger {
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _, _, _)? = route else {
      return Trigger(route: route, generation: nil, anchorExists: false)
    }
    return Trigger(
      route: route,
      generation: environment.navigationStore.workspaceEntries.entry(workspaceId).generation,
      anchorExists: anchorSessionId.map { environment.projectList.session($0, serverId: serverId) != nil } ?? false
    )
  }

  /// Shared Core policy decides whether the current route remains valid,
  /// moves to a surviving sibling chat, or leaves the workspace entirely.
  private var disposition: WorkspaceRouteDisposition {
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _, _, _)? = route else {
      return .keep
    }
    guard let anchorSessionId else {
      guard let workspace = environment.navigationStore.workspaceEntries.entry(workspaceId).workspace,
        workspace.serverId == serverId, !workspace.isArchived
      else { return .dismiss }
      return .keep
    }
    return environment.workspaceSync.routeDisposition(
      workspaceId: workspaceId,
      anchorSessionId: anchorSessionId,
      serverId: serverId
    )
  }
}
