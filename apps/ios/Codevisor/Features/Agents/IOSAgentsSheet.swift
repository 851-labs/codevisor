import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSAgentsSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @Environment(\.sidebarGitLookups) private var gitLookups
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedWorkspaceIDs: [String]
  @State private var renamingWorkspace: Workspace?
  @State private var workspaceRenameTitle = ""
  @State private var renamingAgent: ChatSession?
  @State private var agentRenameTitle = ""

  let agents: [ChatSession]
  let open: (ChatSession) -> Void

  private var rows: [IOSAgentRow] {
    IOSAgentRows(
      environment: environment, gitLookups: gitLookups ?? SidebarGitLookups(),
      rowDetails: ClientPreferences.shared.sidebarRowDetails
    ).rows(for: agents)
  }

  var body: some View {
    NavigationStack {
      List(rows) { row in
        IOSAgentRowView(row: row, actions: actions(for: row))
      }
      .contentMargins(.top, 8, for: .scrollContent)
      .navigationTitle("Agents")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .modifier(
      HomeSidebarAlerts(
        renamingWorkspace: $renamingWorkspace, workspaceRenameTitle: $workspaceRenameTitle,
        onRenameWorkspace: rename)
    )
    .modifier(IOSAgentRenameAlert(renamingAgent: $renamingAgent, title: $agentRenameTitle))
  }

  private func actions(for row: IOSAgentRow) -> IOSAgentRowActions {
    let chat = row.chat
    var actions = IOSAgentRowActions(open: { show(chat) }, setUnread: { setUnread(chat, $0) })
    switch row.subject {
    case .bot:
      break
    case let .workspace(workspace):
      actions.rename = { beginRenaming(workspace) }
      actions.archive = { archive(workspace) }
    case .chat:
      actions.rename = { beginRenaming(chat) }
      actions.archive = { archive(chat) }
    }
    return actions
  }

  private func show(_ chat: ChatSession) {
    dismiss()
    open(chat)
  }

  private func setUnread(_ chat: ChatSession, _ isUnread: Bool) {
    if isUnread {
      environment.projectList.markSessionUnread(chat.id, serverId: chat.serverId)
    } else {
      environment.projectList.markSessionRead(chat.id, serverId: chat.serverId)
    }
  }

  private func beginRenaming(_ workspace: Workspace) {
    workspaceRenameTitle = workspace.name
    renamingWorkspace = workspace
  }

  private func beginRenaming(_ chat: ChatSession) {
    agentRenameTitle = chat.title
    renamingAgent = chat
  }

  private func rename(_ renamed: Workspace) {
    environment.workspaceSync.renameWorkspace(renamed, client: environment.machines.client(for: renamed.serverId))
  }

  private func archive(_ workspace: Workspace) {
    environment.archiveWorkspace(workspace)
    pinnedWorkspaceIDs.removeAll { $0 == workspace.id.uuidString }
    environment.workspaceSections.forget(workspace.id)
  }

  private func archive(_ chat: ChatSession) {
    let client = environment.machines.client(for: chat.serverId)
    Task { try? await client.archiveAgent(id: chat.id) }
  }
}
