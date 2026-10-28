import CodevisorCore
import SwiftUI

struct HomePresentedWorkspaceObserver: View {
  @Environment(AppEnvironment.self) private var environment
  let route: HomeRoute?
  let apply: (WorkspaceRouteDisposition) -> Void

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

  private var disposition: WorkspaceRouteDisposition {
    guard case let .workspace(_, workspaceId, anchorSessionId, _, _, _)? = route else {
      return .keep
    }
    guard let anchorSessionId else {
      guard let workspace = environment.navigationStore.workspaceEntries.entry(workspaceId).workspace,
        !workspace.isArchived
      else { return .dismiss }
      return .keep
    }
    return environment.workspaceSync.routeDisposition(
      workspaceId: workspaceId,
      anchorSessionId: anchorSessionId
    )
  }
}
