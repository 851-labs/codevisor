import CodevisorCore
import CodevisorUI
import SwiftUI

/// The native iOS project step used by the run-target sheet. Existing and
/// recommended projects use a standard list, while an empty machine keeps its
/// creation actions in the empty state.
struct ProjectSelectionScreen: View {
    @Environment(AppEnvironment.self) private var environment

    let serverId: String
    let onSelected: (Project) -> Void

    @State private var recommendations: [ProjectRecommendation] = []
    @State private var addingRecommendationPath: String?
    @State private var showingBrowser = false
    @State private var showingGitClone = false

    private var projects: [Project] {
        environment.projectList
            .fleetActiveProjectsByWorkspaceRecency(environment.workspaces.loadAll())
            .filter { $0.serverId == serverId && !$0.isScratch }
    }

    private var visibleRecommendations: [ProjectRecommendation] {
        let existingPaths = Set(projects.map { $0.folderURL.standardizedFileURL.path })
        return recommendations.filter {
            !existingPaths.contains($0.folderURL.standardizedFileURL.path)
        }
    }

    private var hasChoices: Bool {
        !projects.isEmpty || !visibleRecommendations.isEmpty
    }

    private var machineName: String {
        environment.machines.machine(for: serverId)?.name ?? "this machine"
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }

    var body: some View {
        Group {
            if hasChoices {
                projectList
            } else {
                emptyState
            }
        }
        .task(id: serverId) { await load() }
        .sheet(isPresented: $showingBrowser) {
            AddProjectSheet(serverId: serverId, onAdded: onSelected)
        }
        .sheet(isPresented: $showingGitClone) {
            GitCloneSheet(client: client, machineName: machineName, serverId: serverId) {
                onSelected($0)
            }
        }
    }

    private var projectList: some View {
        List {
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects) { project in
                        Button {
                            onSelected(project)
                        } label: {
                            projectRow(
                                title: project.name,
                                path: project.folderURL.standardizedFileURL.path,
                                systemImage: EntitySystemSymbol.project,
                                showsDisclosure: project.isGitRepository
                            )
                        }
                    }
                }
            }

            if !visibleRecommendations.isEmpty {
                Section("Recommended") {
                    ForEach(visibleRecommendations) { recommendation in
                        Button {
                            add(recommendation)
                        } label: {
                            projectRow(
                                title: recommendation.name,
                                path: recommendation.folderURL.standardizedFileURL.path,
                                systemImage: "clock.arrow.circlepath",
                                isWorking: addingRecommendationPath
                                    == recommendation.folderURL.standardizedFileURL.path
                            )
                        }
                        .disabled(addingRecommendationPath != nil)
                    }
                }
            }

            Section {
                Button {
                    showingBrowser = true
                } label: {
                    Label("Browse Files…", systemImage: "folder.badge.plus")
                }
                Button {
                    showingGitClone = true
                } label: {
                    Label("Clone Repository…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Add Project")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder")
        } description: {
            EmptyView()
        } actions: {
            VStack(spacing: 10) {
                Button("Browse Files…") { showingBrowser = true }
                    .buttonStyle(.borderedProminent)
                Button("Clone Repository…") { showingGitClone = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func projectRow(
        title: String,
        path: String,
        systemImage: String,
        isWorking: Bool = false,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            if isWorking {
                ProgressView()
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(Self.abbreviatedPath(path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        recommendations = []
        async let refresh: ServerNavigationRefreshResult = environment.projectList.refreshFromServer(
            serverId: serverId,
            client: client
        )
        recommendations = (try? await environment.recommendedProjects(serverId: serverId)) ?? []
        _ = await refresh
    }

    private func add(_ recommendation: ProjectRecommendation) {
        guard addingRecommendationPath == nil else { return }
        addingRecommendationPath = recommendation.folderURL.standardizedFileURL.path
        Task {
            let project = await environment.projectList.addProject(
                folderURL: recommendation.folderURL,
                serverId: serverId,
                client: client
            )
            addingRecommendationPath = nil
            onSelected(project)
        }
    }

    private static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
