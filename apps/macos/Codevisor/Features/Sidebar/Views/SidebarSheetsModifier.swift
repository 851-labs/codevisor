import CodevisorCore
import SwiftUI

/// The sidebar's sheets, in the same order they were chained on the sidebar
/// content: project icon picker, workspace icon picker, add-remote-machine.
struct SidebarSheetsModifier: ViewModifier {
    @Binding var iconEditing: Project?
    @Binding var workspaceIconEditing: Workspace?
    @Binding var showingRemoteMachine: Bool
    let list: ProjectListModel
    /// Receives the workspace with its new symbol already applied.
    let onSaveWorkspace: (Workspace) -> Void
    /// Returns an error message to show in the sheet, or nil on success.
    let onAddRemoteMachine: (String, String?, String?) async -> String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $iconEditing) { project in
                IconPickerView(currentSymbol: project.symbolName) { symbol in
                    list.setIcon(symbol, for: project)
                }
            }
            .sheet(item: $workspaceIconEditing) { workspace in
                IconPickerView(
                    currentSymbol: workspace.symbolName ?? list.projects.first {
                        $0.id == workspace.projectId
                    }?.symbolName ?? "square.grid.2x2"
                ) { symbol in
                    var updated = workspace
                    updated.symbolName = symbol
                    onSaveWorkspace(updated)
                }
            }
            .sheet(isPresented: $showingRemoteMachine) {
                RemoteMachineSheet { host, name, token in
                    await onAddRemoteMachine(host, name, token)
                }
            }
    }
}
