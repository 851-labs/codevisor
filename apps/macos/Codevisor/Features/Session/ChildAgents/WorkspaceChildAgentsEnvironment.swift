import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceChildAgentsEnvironment: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var sidebarGrouping
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedWorkspaceIDs: [String]
  let store: SessionStore?
  @Binding var selection: SidebarSelection?
  var revealRequest: SidebarRevealRequest?

  func body(content: Content) -> some View {
    content.environment(\.workspaceChildAgents, childAgents)
  }

  private var childAgents: WorkspaceChildAgents? {
    guard let store else { return nil }
    return WorkspaceChildAgents(
      environment: environment, store: store, botsEnabled: botsEnabled, grouping: sidebarGrouping,
      pinnedIDs: pinnedWorkspaceIDs, selection: $selection, revealRequest: revealRequest)
  }
}
