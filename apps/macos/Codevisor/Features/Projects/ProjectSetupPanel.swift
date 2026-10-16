import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorUI

@MainActor
@Observable
final class ProjectSetupModel {
  struct FolderChoice: Identifiable {
    let url: URL
    let title: String
    let subtitle: String
    var id: String { url.standardizedFileURL.path }
  }

  var recommendations: [ProjectRecommendation] = []
  var isLoadingRecommendations = true
  var customFolders: [URL] = []
  var clonedProjects: [Project] = []
  var selectedFolders: [URL] = []

  var folderChoices: [FolderChoice] {
    let clonedPaths = Set(clonedProjects.map { $0.folderURL.standardizedFileURL.path })
    let cloned = clonedProjects.map { project in
      FolderChoice(
        url: project.folderURL,
        title: project.name,
        subtitle: "Cloned · \(Self.abbreviatedPath(project.folderURL))"
      )
    }
    let custom =
      customFolders
      .filter { !clonedPaths.contains($0.standardizedFileURL.path) }
      .map { url in
        FolderChoice(
          url: url,
          title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
          subtitle: Self.abbreviatedPath(url)
        )
      }
    let suggested =
      recommendations
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

  var deselectedClonedProjects: [Project] {
    clonedProjects.filter { !isSelected($0.folderURL) }
  }

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

struct ProjectSetupSelectionView: View {
  let model: ProjectSetupModel
  let isLocalMachine: Bool
  let machineName: String
  let onPickFolder: () -> Void
  let onCloneRepository: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.isLoadingRecommendations {
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
            GridItem(.flexible(), spacing: 8),
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
          .fill(isSelected ? Color.primary.opacity(0.14) : Color.cardBackgroundColor)
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
        : "Browse Files…"
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

struct ProjectSetupPanel: View {
  @Environment(AppEnvironment.self) private var environment

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

      Button {
        confirm()
      } label: {
        Text(
          model.selectedFolders.count > 1
            ? "Add \(model.selectedFolders.count) Projects"
            : "Open Project"
        )
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
    .task(id: targetServerId) {
      model.clearStagedWork()
      model.isLoadingRecommendations = true
      model.recommendations = await environment.recommendedProjectsWithFallback(
        serverId: targetServerId
      )
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

  private func confirm() {
    for project in model.deselectedClonedProjects {
      environment.projectList.removeProject(project)
    }
    var first: Project?
    for url in model.selectedFolders {
      let project = environment.projectList.addProject(
        folderURL: url,
        serverId: targetServerId
      )
      if first == nil { first = project }
    }
    if let first { onComplete(first) }
  }

  private var isLocalMachine: Bool {
    targetMachine?.isLocal ?? false
  }

  private var machineName: String {
    targetMachine?.name ?? "Machine"
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: targetServerId)
  }

  private var targetServerId: String {
    environment.defaultComposerServerId
  }

  private var targetMachine: CodevisorMachine? {
    environment.machines.machine(for: targetServerId)
  }
}

struct ProjectSetupActionCard: View {
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
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackgroundColor))
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
