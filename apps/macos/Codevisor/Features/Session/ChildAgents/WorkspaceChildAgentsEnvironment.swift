import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceChildAgentsEnvironment: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedWorkspaceIDs: [String]
  @State private var renamingWorkspace: Workspace?
  @State private var renamingChat: ChatSession?
  @State private var sectionPrompt: SectionPrompt?
  let store: SessionStore?
  @Binding var selection: SidebarSelection?
  var revealRequest: SidebarRevealRequest?

  func body(content: Content) -> some View {
    content
      .environment(\.workspaceChildAgents, childAgents)
      .modifier(WorkspaceRenamePrompt(request: $renamingWorkspace))
      .modifier(AgentRenamePrompt(request: $renamingChat))
      .modifier(SectionPromptModifier(prompt: $sectionPrompt, store: environment.workspaceSections))
  }

  private var childAgents: WorkspaceChildAgents? {
    guard let store else { return nil }
    return WorkspaceChildAgents(
      environment: environment, store: store, commands: commands, renameChat: { renamingChat = $0 },
      selection: $selection, revealRequest: revealRequest)
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
