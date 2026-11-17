import CodevisorCore
import CodevisorUI
import SwiftUI

struct RestoringWorkspacePane: View {
  @Environment(AppEnvironment.self) private var environment
  let workspace: Workspace
  @State private var progress = SandboxRestoreProgress()
  @State private var disclosure = TranscriptDisclosureStore()

  var body: some View {
    let restoring = environment.machines.restoringWorkspace(workspace.id)
    ScrollView {
      SessionSetupView(phases: progress.phases)
        .frame(maxWidth: VirtualizedTranscriptScrollView.maxRowWidth)
        .padding(.horizontal, VirtualizedTranscriptScrollView.horizontalPadding)
        .padding(.top, VirtualizedTranscriptScrollView.topPadding)
        .frame(maxWidth: .infinity)
    }
    .environment(\.transcriptDisclosure, disclosure)
    .task(id: restoring?.sandboxId) {
      guard let restoring else { return }
      await progress.follow(
        restoring, clonedProjectName: clonedProjectName,
        client: environment.machines.client(for: workspace.serverId))
    }
  }

  private var clonedProjectName: String? {
    environment.projectList.projects
      .first { $0.serverId == workspace.serverId && $0.id == workspace.projectId && $0.repoUrl != nil }?
      .name
  }
}
