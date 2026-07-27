import CodevisorCore
import CodevisorUI
import SwiftUI

/// The New Workspace flow, matching macOS: pick a project and the workspace
/// opens immediately with a fresh chat pane. Harness and run-location choices
/// live under the composer in that pane, exactly like the macOS new-chat
/// page.
struct NewWorkspaceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Called with the created session so the caller can navigate into it.
    let onCreated: (ChatSession) -> Void

    private var projects: [Project] {
        // Recency: projects whose chats were touched most recently first —
        // the iOS stand-in for macOS's workspace-recency ordering.
        let sessions = environment.projectList.sessions
        var latest: [UUID: Date] = [:]
        for session in sessions {
            let stamp = session.updatedAt ?? session.createdAt
            if latest[session.projectId] == nil || latest[session.projectId]! < stamp {
                latest[session.projectId] = stamp
            }
        }
        return environment.projectList.activeProjects.sorted {
            (latest[$0.id] ?? .distantPast) > (latest[$1.id] ?? .distantPast)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "folder")
                    } description: {
                        Text("Add a project from Codevisor on your machine, then it appears here.")
                    }
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(projects) { project in
                            Button {
                                create(in: project)
                            } label: {
                                ProjectCard(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await environment.projectList.refreshFromServer()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Same as macOS `createWorkspaceSession(in:)`: mint the deferred session
    /// now (the agent spawns server-side on the first send) and jump straight
    /// into its chat pane.
    private func create(in project: Project) {
        let session = environment.projectList.newSession(in: project, title: "New Chat")
        dismiss()
        onCreated(session)
    }
}

/// A project card: filled symbol, name, tilde-abbreviated path — the iOS
/// twin of the macOS New Workspace project card.
private struct ProjectCard: View {
    let project: Project

    private var abbreviatedPath: String {
        let path = project.folderURL.path
        if let range = path.range(of: "/Users/[^/]+", options: .regularExpression),
           range.lowerBound == path.startIndex {
            return "~" + path[range.upperBound...]
        }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: project.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(project.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(abbreviatedPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
