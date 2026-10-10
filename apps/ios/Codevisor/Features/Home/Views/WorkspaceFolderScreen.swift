import CodevisorCore
import SwiftUI

/// A folder's page, as Notes opens a folder: the workspaces filed in it,
/// each opening its own page or disclosing the workspaces nested under it,
/// reordered by dragging. Its menu renames or deletes the folder.
struct WorkspaceFolderScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.workspaceRowActions) private var actions
  @Environment(\.dismiss) private var dismiss

  let folderId: UUID

  @State private var expanded: Set<UUID> = []
  @State private var isRenaming = false
  @State private var name = ""
  @State private var isDeleting = false

  private var navigation: NavigationStore { environment.navigationStore }

  var body: some View {
    // The projection isn't observed directly; the revision is what changes.
    let _ = navigation.revision
    let filed = folder
    List {
      if let filed, !filed.rows.isEmpty {
        WorkspaceOutline(rows: filed.rows, owner: nil, expanded: $expanded)
      }
    }
    .listStyle(.insetGrouped)
    .overlay {
      if filed?.rows.isEmpty ?? true {
        ContentUnavailableView("No Workspaces", systemImage: "folder")
      }
    }
    .navigationTitle(filed?.folder.name ?? "")
    .toolbar {
      if let filed {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("Rename", systemImage: "pencil") {
              name = filed.folder.name
              isRenaming = true
            }
            Button("Delete Folder…", systemImage: "trash", role: .destructive) { isDeleting = true }
          } label: {
            Label("More", systemImage: "ellipsis")
          }
        }
      }
    }
    .alert("Rename Folder", isPresented: $isRenaming) {
      TextField("Name", text: $name)
      Button("Rename") { rename() }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      filed.map { "Delete “\($0.folder.name)”?" } ?? "", isPresented: $isDeleting, titleVisibility: .visible
    ) {
      if let filed {
        Button("Delete Folder") { delete(archiving: []) }
        let count = filed.rows.count
        if count > 0 {
          Button("Delete Folder and \(count) Workspace\(count == 1 ? "" : "s")", role: .destructive) {
            delete(archiving: filed.rows.map(\.id))
          }
        }
        Button("Cancel", role: .cancel) {}
      }
    }
  }

  /// The folder and the workspaces filed in it, as the sidebar has them.
  private var folder: (folder: ServerNavigationFolder, rows: [AgentSidebarRow])? {
    for case let .folder(folder, rows) in navigation.agentSidebar where UUID(uuidString: folder.id) == folderId {
      return (folder, rows)
    }
    return nil
  }

  private func rename() {
    guard let filed = folder else { return }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    navigation.saveFolder(id: folderId, name: name, position: filed.folder.position, collapsed: filed.folder.collapsed)
  }

  private func delete(archiving workspaces: [UUID]) {
    for id in workspaces { actions.archive(id) }
    navigation.deleteFolder(id: folderId)
    dismiss()
  }
}
