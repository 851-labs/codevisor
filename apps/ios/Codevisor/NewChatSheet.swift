import CodevisorCore
import SwiftUI

/// Starting fresh work from the phone: pick a project and an agent, get a
/// deferred session (the agent spawns server-side on the first send — the
/// same connect-on-first-send path the macOS composer uses).
struct NewChatSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Called with the created session so the caller can navigate into it.
    let onCreated: (ChatSession) -> Void

    @State private var selectedProjectId: UUID?
    @State private var harnesses: [ServerHarness] = []
    @State private var selectedHarnessId: String?
    @State private var isLoadingHarnesses = true

    private var projects: [Project] { environment.projectList.activeProjects }

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    Picker("Project", selection: $selectedProjectId) {
                        ForEach(projects) { project in
                            Label(project.name, systemImage: project.symbolName)
                                .tag(Optional(project.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Agent") {
                    if isLoadingHarnesses {
                        HStack { ProgressView(); Text("Loading agents…").foregroundStyle(.secondary) }
                    } else if harnesses.isEmpty {
                        Text("No agents are ready on this machine.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Agent", selection: $selectedHarnessId) {
                            ForEach(harnesses, id: \.id) { harness in
                                Text(harness.name).tag(Optional(harness.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .disabled(selectedProject == nil || selectedHarnessId == nil)
                }
            }
            .task {
                if selectedProjectId == nil { selectedProjectId = projects.first?.id }
                harnesses = await environment.harnessService.readyHarnesses()
                if selectedHarnessId == nil { selectedHarnessId = harnesses.first?.id }
                isLoadingHarnesses = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func start() {
        guard let project = selectedProject, let harnessId = selectedHarnessId else { return }
        let session = environment.projectList.newSession(
            in: project,
            title: "New Chat",
            harnessId: harnessId
        )
        dismiss()
        onCreated(session)
    }
}
