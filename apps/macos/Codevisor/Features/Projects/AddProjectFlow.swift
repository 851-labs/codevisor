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
    /// The machine the project lands on. nil follows the selected machine
    /// (sidebar, onboarding); pickers that name a machine pass it so an
    /// empty fleet machine can get its first project.
    var serverId: String?

    func begin(serverId: String? = nil) {
        self.serverId = serverId
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
                    if isLocalTarget {
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
                    let serverId = targetServerId
                    let client = client
                    Task {
                        onAdded(
                            await environment.projectList.addProject(folderURL: url, serverId: serverId, client: client)
                        )
                    }
                }
            }
            .sheet(isPresented: $flow.showingRemoteBrowser) {
                RemoteDirectoryBrowserSheet(client: client, machineName: machineName) { path in
                    let serverId = targetServerId
                    let client = client
                    Task {
                        onAdded(
                            await environment.projectList.addProject(
                                folderURL: URL(fileURLWithPath: path),
                                serverId: serverId,
                                client: client
                            )
                        )
                    }
                }
            }
            .sheet(isPresented: $flow.showingGitClone) {
                GitCloneSheet(client: client, machineName: machineName) { project in
                    onAdded(project)
                }
            }
    }

    private var targetServerId: String {
        flow.serverId ?? environment.machines.selectedMachineId
    }

    private var targetMachine: CodevisorMachine? {
        environment.machines.machine(for: targetServerId)
    }

    private var isLocalTarget: Bool {
        targetMachine?.isLocal ?? environment.machines.selectedMachine.isLocal
    }

    private var folderButtonTitle: String {
        isLocalTarget ? "Choose Folder…" : "Browse \(machineName)…"
    }

    private var machineName: String {
        targetMachine?.name ?? environment.machines.selectedMachine.name
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: targetServerId)
    }
}
