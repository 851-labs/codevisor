import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceChildAgentsEnvironment: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var sidebarGrouping
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedWorkspaceIDs: [String]
  @State private var renamingWorkspace: Workspace?
  @State private var sectionPrompt: SectionPrompt?
  let store: SessionStore?
  @Binding var selection: SidebarSelection?
  var revealRequest: SidebarRevealRequest?

  func body(content: Content) -> some View {
    content
      .environment(\.workspaceChildAgents, childAgents)
      .modifier(WorkspaceRenamePrompt(request: $renamingWorkspace))
      .modifier(SectionPromptModifier(prompt: $sectionPrompt, store: environment.workspaceSections))
  }

  private var childAgents: WorkspaceChildAgents? {
    guard let store else { return nil }
    return WorkspaceChildAgents(
      environment: environment, store: store, botsEnabled: botsEnabled, grouping: sidebarGrouping,
      commands: commands, selection: $selection, revealRequest: revealRequest)
  }

  private var commands: WorkspaceRowCommands {
    WorkspaceRowCommands(
      environment: environment,
      pinnedIDs: $pinnedWorkspaceIDs,
      rename: { renamingWorkspace = $0 },
      newSection: { sectionPrompt = .create(moving: $0.id) }
    )
  }
}
