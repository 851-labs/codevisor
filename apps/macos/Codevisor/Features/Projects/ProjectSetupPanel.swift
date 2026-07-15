import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore

// MARK: - Model

/// Selection state for the project setup grid shared by onboarding's project
/// step and the new-chat empty state: folder suggestions from the machine's
/// recent harness sessions, hand-picked folders, and freshly cloned
/// repositories, multi-selected before being added as projects in one go.
@MainActor
@Observable
final class ProjectSetupModel {
    /// A selectable folder row: a recommendation, a custom pick, or a clone.
    struct FolderChoice: Identifiable {
        let url: URL
        let title: String
        let subtitle: String
        var id: String { url.standardizedFileURL.path }
    }

    var recommendations: [ProjectRecommendation] = []
    var isLoadingRecommendations = true
    /// Folders added through the open panel or remote browser (they aren't in
    /// `recommendations` but should render as selectable rows alongside them).
    var customFolders: [URL] = []
    /// Projects created by cloning. They already exist (the clone registers
    /// them immediately); they render as selectable rows, and confirming with
    /// one deselected removes it again.
    var clonedProjects: [Project] = []
    /// Folders the user has ticked, in selection order — the first one is the
    /// project a new chat opens in afterwards.
    var selectedFolders: [URL] = []

    /// Cloned and hand-picked rows first (most deliberate), then suggestions.
    var folderChoices: [FolderChoice] {
        let clonedPaths = Set(clonedProjects.map { $0.folderURL.standardizedFileURL.path })
        let cloned = clonedProjects.map { project in
            FolderChoice(
                url: project.folderURL,
                title: project.name,
                subtitle: "Cloned · \(Self.abbreviatedPath(project.folderURL))"
            )
        }
        let custom = customFolders
            .filter { !clonedPaths.contains($0.standardizedFileURL.path) }
            .map { url in
                FolderChoice(
                    url: url,
                    title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                    subtitle: Self.abbreviatedPath(url)
                )
            }
        let suggested = recommendations
            .filter { recommendation in
                let path = recommendation.folderURL.standardizedFileURL.path
                return !clonedPaths.contains(path)
                    && !customFolders.contains { $0.standardizedFileURL.path == path }
            }
            .map { recommendation in
                FolderChoice(
                    url: recommendation.folderURL,
                    title: recommendation.name,
                    subtitle: Self.recommendationSubtitle(recommendation)
                )
            }
        return cloned + custom + suggested
    }

    /// Cloned projects the user deselected before confirming — "don't keep
    /// it" (the checkout stays on disk, only the project entry is removed).
    var deselectedClonedProjects: [Project] {
        clonedProjects.filter { !isSelected($0.folderURL) }
    }

    /// Whether the user has staged anything not yet confirmed. The new-chat
    /// page keeps the setup panel on screen while this is true — a clone
    /// registers its project immediately, which would otherwise flip the
    /// page to the composer instead of showing the clone as a selected row.
    var hasStagedWork: Bool {
        !selectedFolders.isEmpty || !customFolders.isEmpty || !clonedProjects.isEmpty
    }

    /// Drops staged selections (used when the selected machine changes —
    /// folders staged for one machine don't apply to another). Suggestions
    /// are cleared too; the caller reloads them for the new machine.
    func clearStagedWork() {
        selectedFolders = []
        customFolders = []
        clonedProjects = []
        recommendations = []
    }

    func isSelected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return selectedFolders.contains { $0.standardizedFileURL.path == path }
    }

    func toggleSelection(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let index = selectedFolders.firstIndex(where: { $0.standardizedFileURL.path == path }) {
            selectedFolders.remove(at: index)
        } else {
            selectedFolders.append(url)
        }
    }

    /// Folders picked in the open panel or remote browser join the list
    /// pre-selected; picks that match an existing suggestion just select
    /// that suggestion's row.
    func addPickedFolders(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            let isRecommended = recommendations.contains {
                $0.folderURL.standardizedFileURL.path == path
            }
            let isCustom = customFolders.contains { $0.standardizedFileURL.path == path }
            if !isRecommended && !isCustom {
                customFolders.append(url)
            }
            if !isSelected(url) {
                selectedFolders.append(url)
            }
        }
    }

    /// A clone finished: the project already exists, so it joins the grid as
    /// a pre-selected row (deselecting it before confirming removes it again).
    func cloneCompleted(_ project: Project) {
        if !clonedProjects.contains(where: { $0.id == project.id }) {
            clonedProjects.append(project)
        }
        if !isSelected(project.folderURL) {
            selectedFolders.append(project.folderURL)
        }
    }

    static func recommendationSubtitle(_ recommendation: ProjectRecommendation) -> String {
        let chats = recommendation.sessionCount == 1 ? "1 chat" : "\(recommendation.sessionCount) chats"
        return "\(chats) · \(abbreviatedPath(recommendation.folderURL))"
    }

    static func abbreviatedPath(_ url: URL) -> String {
        (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Selection grid

/// The project setup grid: suggested/picked/cloned folder rows in a
/// two-column multi-select grid, with "add another folder" and "clone a
/// repository" rows beneath. Extracted from onboarding's project step and
/// reused verbatim on the new-chat empty state so both surfaces look and
/// behave identically. The caller owns the pickers/sheets (and the confirm
/// button) — this view only reports intent via the two callbacks.
struct ProjectSetupSelectionView: View {
    @Environment(\.theme) private var theme

    let model: ProjectSetupModel
    let isLocalMachine: Bool
    let machineName: String
    let onPickFolder: () -> Void
    let onCloneRepository: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoadingRecommendations {
                // HIG: recommendation discovery has no measurable duration,
                // so show a small indeterminate activity indicator where
                // its results will appear. Keep the manual picker available.
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .help("Finding recent projects")
                        .accessibilityLabel("Finding recent projects")
                    Spacer()
                }
                .frame(minHeight: 64)
            } else if !model.folderChoices.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(model.folderChoices) { choice in
                        folderChoiceRow(choice)
                    }
                }
            }

            VStack(spacing: 8) {
                addFolderButton
                cloneRepositoryButton
            }
            .padding(.top, model.folderChoices.isEmpty ? 0 : 4)
        }
    }

    private func folderChoiceRow(_ choice: ProjectSetupModel.FolderChoice) -> some View {
        let isSelected = model.isSelected(choice.url)
        return Button {
            model.toggleSelection(choice.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(choice.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(theme.rowSelectedBackground) : theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(choice.url.standardizedFileURL.path)
        .accessibilityLabel("\(choice.title), \(choice.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.15), value: isSelected)
    }

    private var addFolderButton: some View {
        ProjectSetupActionCard(
            systemImage: "plus.circle",
            title: isLocalMachine
                ? (model.folderChoices.isEmpty ? "Choose a folder…" : "Add another folder…")
                : "Browse \(machineName)…"
        ) {
            onPickFolder()
        }
    }

    private var cloneRepositoryButton: some View {
        ProjectSetupActionCard(
            systemImage: "square.and.arrow.down",
            title: "Clone a repository…"
        ) {
            onCloneRepository()
        }
    }
}

// MARK: - Self-contained panel (new-chat empty state)

/// Onboarding's project setup, self-contained for the new-chat page: loads
/// suggestions from the selected machine's recent harness sessions, owns the
/// pickers (native importer locally, remote browser otherwise) and the
/// git-clone sheet, and confirms with the same "Open Project"/"Add N
/// Projects" button. `onComplete` receives the first selected project so the
/// caller can open a new chat in it.
struct ProjectSetupPanel: View {
    @Environment(AppEnvironment.self) private var environment

    /// Owned by the caller so staged work (a completed clone, ticked rows)
    /// survives the project list changing underneath the page — the caller
    /// keeps the panel visible while `model.hasStagedWork`.
    let model: ProjectSetupModel
    let onComplete: (Project) -> Void

    @State private var showingFolderPicker = false
    @State private var showingRemoteBrowser = false
    @State private var showingGitClone = false

    var body: some View {
        VStack(spacing: 20) {
            ProjectSetupSelectionView(
                model: model,
                isLocalMachine: isLocalMachine,
                machineName: machineName,
                onPickFolder: {
                    if isLocalMachine {
                        showingFolderPicker = true
                    } else {
                        showingRemoteBrowser = true
                    }
                },
                onCloneRepository: { showingGitClone = true }
            )

            // Always present (disabled until something is selected) so the
            // layout doesn't shift when the first row is ticked.
            Button {
                confirm()
            } label: {
                Text(model.selectedFolders.count > 1
                    ? "Add \(model.selectedFolders.count) Projects"
                    : "Open Project")
                .contentTransition(.numericText())
                .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedFolders.isEmpty)
            .animation(.snappy(duration: 0.2), value: model.selectedFolders.count)
        }
        .frame(maxWidth: 560)
        .task(id: environment.machines.selectedMachineId) {
            // A machine switch mid-setup drops the staged folders — they
            // belong to the previous machine. (No-op on first appearance.)
            model.clearStagedWork()
            model.isLoadingRecommendations = true
            model.recommendations = await environment.recommendedProjects()
            model.isLoadingRecommendations = false
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                model.addPickedFolders(urls)
            }
        }
        .sheet(isPresented: $showingRemoteBrowser) {
            RemoteDirectoryBrowserSheet(client: client, machineName: machineName) { path in
                model.addPickedFolders([URL(fileURLWithPath: path)])
            }
        }
        .sheet(isPresented: $showingGitClone) {
            GitCloneSheet(client: client, machineName: machineName) { project in
                model.cloneCompleted(project)
            }
        }
    }

    /// Adds every selected folder as a project (cloned ones are reused, not
    /// duplicated), removes clones the user deselected, and hands the first
    /// selection to the caller.
    private func confirm() {
        for project in model.deselectedClonedProjects {
            environment.projectList.removeProject(project)
        }
        var first: Project?
        for url in model.selectedFolders {
            let project = environment.projectList.addProject(folderURL: url)
            if first == nil { first = project }
        }
        if let first { onComplete(first) }
    }

    private var isLocalMachine: Bool {
        environment.machines.selectedMachine.isLocal
    }

    private var machineName: String {
        environment.machines.selectedMachine.name
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: environment.machines.selectedMachineId)
    }
}

// MARK: - Action card

/// The card-style action row shared by the setup grid's "Add another
/// folder…" / "Clone a repository…" rows, so every add-project affordance
/// looks and behaves the same.
struct ProjectSetupActionCard: View {
    @Environment(\.theme) private var theme

    let systemImage: String
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }
}

#Preview("New-chat panel") {
    ProjectSetupPanel(model: ProjectSetupModel()) { _ in }
        .environment(AppEnvironment.preview())
        .padding(40)
        .frame(width: 640)
}
