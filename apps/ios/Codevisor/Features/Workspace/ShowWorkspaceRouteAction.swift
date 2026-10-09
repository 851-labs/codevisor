import CodevisorCore
import SwiftUI

/// Shows another workspace in this one's place, as opening a subagent's tab
/// group from the tab overview does. Back still returns to the agent list,
/// not to the workspace it replaced.
struct ShowWorkspaceRouteAction {
  var handler: @MainActor (HomeRoute) -> Void = { _ in }

  @MainActor
  func callAsFunction(_ route: HomeRoute) { handler(route) }
}

extension EnvironmentValues {
  @Entry var showWorkspaceRoute = ShowWorkspaceRouteAction()
}
