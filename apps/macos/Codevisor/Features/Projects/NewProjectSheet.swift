import CodevisorCore
import CodevisorUI
import SwiftUI
import UniformTypeIdentifiers

/// Adds a project on one machine. Suggestions exclude folders that are
/// already registered; existing projects stay in the composer's inline menu.
struct NewProjectSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let serverId: String
    let onAdded: (Project) -> Void

    @State private var recommendations: [ProjectRecommendation] = []
    @State private var isLoading = true
    @State private var selectedPath: String?
    @State private var isAdding = false
    @State private var showingLocalImporter = false
    @State private var showingRemoteBrowser = false
    @State private var showingGitClone = false

    private var registeredPaths: Set<String> {
        Set(
            environment.projectList.fleetActiveProjects
                .filter { $0.serverId == serverId && !$0.isScratch }
                .map { $0.folderURL.standardizedFileURL.path }
        )
    }

    private var visibleRecommendations: [ProjectRecommendation] {
        recommendations.filter {
            !registeredPaths.contains($0.folderURL.standardizedFileURL.path)
        }
    }

    private var selectedRecommendation: ProjectRecommendation? {
        guard let selectedPath else { return nil }
        return visibleRecommendations.first {
            $0.folderURL.standardizedFileURL.path == selectedPath
        }
    }

    private var machine: CodevisorMachine? {
        environment.machines.machine(for: serverId)
    }

    private var machineName: String {
        machine?.name ?? "this machine"
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 420)
        .task(id: serverId) { await load() }
        .fileImporter(
            isPresented: $showingLocalImporter,
            allowedContentTypes: [.folder]
        ) { result in
            if case let .success(url) = result {
                addFolder(url)
            }
        }
        .sheet(isPresented: $showingRemoteBrowser) {
            RemoteDirectoryBrowserSheet(client: client, machineName: machineName) { path in
                addFolder(URL(fileURLWithPath: path))
            }
        }
        .sheet(isPresented: $showingGitClone) {
            GitCloneSheet(client: client, machineName: machineName, serverId: serverId) {
                complete($0)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Add Project")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Finding projects")
        } else if visibleRecommendations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("No Projects")
                    .font(.title3.weight(.semibold))
                Button("Browse Files…") { browseFiles() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAdding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedPath) {
                ForEach(visibleRecommendations) { recommendation in
                    recommendationRow(recommendation)
                }
                browseFilesRow
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Clone Repository…") { showingGitClone = true }
                .disabled(isAdding)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isAdding)
            Button {
                addSelection()
            } label: {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 36)
                } else {
                    Text("Add")
                        .frame(minWidth: 36)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedRecommendation == nil || isAdding)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func recommendationRow(_ recommendation: ProjectRecommendation) -> some View {
        let path = recommendation.folderURL.standardizedFileURL.path
        return HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text(recommendation.name)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(Self.abbreviatedPath(path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .tag(path)
        .help(path)
    }

    private var browseFilesRow: some View {
        Button {
            browseFiles()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 16)
                Text("Browse Files…")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(isAdding)
    }

    private func browseFiles() {
        if machine?.isLocal == true {
            showingLocalImporter = true
        } else {
            showingRemoteBrowser = true
        }
    }

    private func load() async {
        isLoading = true
        recommendations = []
        async let refresh: ServerNavigationRefreshResult = environment.projectList.refreshFromServer(
            serverId: serverId,
            client: client
        )
        let loaded = (try? await environment.recommendedProjects(serverId: serverId)) ?? []
        _ = await refresh
        guard !Task.isCancelled else { return }
        recommendations = loaded
        isLoading = false
    }

    private func addSelection() {
        guard !isAdding, let selectedRecommendation else { return }
        addFolder(selectedRecommendation.folderURL)
    }

    private func addFolder(_ url: URL) {
        guard !isAdding else { return }
        isAdding = true
        Task {
            let project = await environment.projectList.addProject(
                folderURL: url,
                serverId: serverId,
                client: client
            )
            complete(project)
        }
    }

    private func complete(_ project: Project) {
        onAdded(project)
        dismiss()
    }

    private static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
