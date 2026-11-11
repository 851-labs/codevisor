import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceRenamePrompt: ViewModifier {
  @Binding var request: Workspace?
  @Environment(AppEnvironment.self) private var environment
  @State private var name = ""
  @State private var presented: Workspace?

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename Workspace",
        isPresented: Binding(get: { presented != nil }, set: { if !$0 { dismiss() } }),
        presenting: presented
      ) { workspace in
        TextField("Name", text: $name)
        Button("Rename") { rename(workspace) }
        Button("Cancel", role: .cancel) {}
      }
      .focusesAlertTextField(when: presented != nil)
      .onChange(of: request?.id) { present(request) }
  }

  private func present(_ workspace: Workspace?) {
    name = workspace?.name ?? ""
    presented = workspace
  }

  private func dismiss() {
    presented = nil
    request = nil
  }

  private func rename(_ workspace: Workspace) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    var renamed = workspace
    renamed.name = trimmed
    renamed.hasCustomName = true
    environment.workspaceSync.renameWorkspace(renamed, client: environment.machines.client(for: renamed.serverId))
  }
}
