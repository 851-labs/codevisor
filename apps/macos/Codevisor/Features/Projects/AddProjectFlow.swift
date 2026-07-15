import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore

/// The shared add-project flow: one entry point that asks where the project
/// comes from — a folder that already exists on the selected machine, or a
/// fresh clone of a git remote — and routes to the right picker. Used by the
/// sidebar's add button, the new-chat project menu, and onboarding, so all
/// three surfaces behave identically on local and remote machines.
@MainActor
@Observable
final class AddProjectFlow {
    var showingSourcePicker = false
    var showingLocalImporter = false
    var showingRemoteBrowser = false
    var showingGitClone = false

    func begin() {
        showingSourcePicker = true
    }
}

extension View {
    /// Attaches the add-project pickers and sheets. `onAdded` runs after the
    /// project is registered locally, so callers can select or expand it.
    func addProjectFlow(_ flow: AddProjectFlow, onAdded: @escaping (Project) -> Void) -> some View {
        modifier(AddProjectFlowModifier(flow: flow, onAdded: onAdded))
    }
}

private struct AddProjectFlowModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var flow: AddProjectFlow
    let onAdded: (Project) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Add Project",
                isPresented: $flow.showingSourcePicker,
                titleVisibility: .visible
            ) {
                Button("Clone Git Repository…") {
                    flow.showingGitClone = true
                }
                Button(folderButtonTitle) {
                    if environment.machines.selectedMachine.isLocal {
                        flow.showingLocalImporter = true
                    } else {
                        flow.showingRemoteBrowser = true
                    }
                }
            } message: {
                Text("Clone a repository onto \(machineName), or use a folder already on it.")
            }
            .fileImporter(
                isPresented: $flow.showingLocalImporter,
                allowedContentTypes: [.folder]
            ) { result in
                if case let .success(url) = result {
                    onAdded(environment.projectList.addProject(folderURL: url))
                }
            }
            .sheet(isPresented: $flow.showingRemoteBrowser) {
                RemoteDirectoryBrowserSheet(client: client, machineName: machineName) { path in
                    onAdded(environment.projectList.addProject(folderURL: URL(fileURLWithPath: path)))
                }
            }
            .sheet(isPresented: $flow.showingGitClone) {
                GitCloneSheet(client: client, machineName: machineName) { project in
                    onAdded(project)
                }
            }
    }

    private var folderButtonTitle: String {
        environment.machines.selectedMachine.isLocal
            ? "Choose Folder…"
            : "Browse \(machineName)…"
    }

    private var machineName: String {
        environment.machines.selectedMachine.name
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: environment.machines.selectedMachineId)
    }
}
