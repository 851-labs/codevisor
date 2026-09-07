import CodevisorCore
import CodevisorUI
import SwiftUI
import UniformTypeIdentifiers

/// Adds a project on one machine. Suggestions exclude folders that are
/// already registered. The selected machine is local to this sheet.
struct NewProjectSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme

  @State private var serverId: String
  let onAdded: (Project) -> Void

  @State private var recommendations: [ProjectRecommendation] = []
  @State private var isLoading = true
  @State private var selectedPath: String?
  @State private var isAdding = false
  @State private var showingLocalImporter = false
  @State private var showingRemoteBrowser = false
  @State private var showingGitClone = false
  @State private var loadError: String?
  @State private var loadGeneration = 0

  init(serverId: String, onAdded: @escaping (Project) -> Void) {
    _serverId = State(initialValue: serverId)
    self.onAdded = onAdded
  }

  private var isTargetReady: Bool {
    environment.machines.availability(for: serverId) == .ready
  }

  private var machineSelection: Binding<String> {
    Binding(
      get: { serverId },
      set: {
        loadGeneration += 1
        serverId = $0
        recommendations = []
        selectedPath = nil
        loadError = nil
        isLoading = true
      }
    )
  }

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
    .themedSurface(.sheet)
    .interactiveDismissDisabled(isAdding)
    .task(id: "\(serverId):\(isTargetReady)") { await load(serverId: serverId) }
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
    VStack(alignment: .leading, spacing: 12) {
      Text("Add Project")
        .font(.title2.weight(.semibold))
      if environment.machines.allMachines.count > 1 {
        Picker("Machine", selection: machineSelection) {
          ForEach(environment.machines.allMachines) { machine in
            Text(machine.name).tag(machine.id)
              .disabled(environment.machines.availability(for: machine.id) != .ready)
          }
        }
        .disabled(isAdding || showingLocalImporter || showingRemoteBrowser || showingGitClone)
      } else {
        Text(machineName).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  @ViewBuilder
  private var content: some View {
    if !isTargetReady {
      ContentUnavailableView(
        "Machine Unavailable", systemImage: "desktopcomputer",
        description: Text("Reconnect \(machineName) or choose another machine to add a project.")
      )
    } else if isLoading {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Finding projects")
    } else if visibleRecommendations.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "folder")
          .font(.system(size: 32, weight: .regular))
          .foregroundStyle(.secondary)
        Text(loadError == nil ? "No Projects" : "Couldn't Find Projects")
          .font(.title3.weight(.semibold))
        if let loadError {
          Text(loadError)
            .foregroundStyle(theme.statusError)
            .font(.callout)
            .multilineTextAlignment(.center)
          Button("Retry") { Task { await load(serverId: serverId) } }
            .disabled(isAdding)
        }
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
        .disabled(isAdding || !isTargetReady)
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
      .disabled(selectedRecommendation == nil || isAdding || !isTargetReady)
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

  private func load(serverId: String) async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    recommendations = []
    selectedPath = nil
    loadError = nil
    guard isTargetReady else {
      isLoading = false
      return
    }
    let client = environment.machines.client(for: serverId)
    async let refresh: ServerNavigationRefreshResult = environment.projectList.refreshFromServer(
      serverId: serverId,
      client: client
    )
    let loaded: [ProjectRecommendation]
    let errorMessage: String?
    do {
      loaded = try await environment.recommendedProjects(serverId: serverId)
      errorMessage = nil
    } catch {
      loaded = []
      errorMessage = serverErrorMessage(error)
    }
    _ = await refresh
    guard !Task.isCancelled, self.serverId == serverId, generation == loadGeneration else { return }
    recommendations = loaded
    loadError = errorMessage
    isLoading = false
  }

  private func addSelection() {
    guard !isAdding, let selectedRecommendation else { return }
    addFolder(selectedRecommendation.folderURL)
  }

  private func addFolder(_ url: URL) {
    guard !isAdding, isTargetReady else { return }
    isAdding = true
    let serverId = serverId
    let client = client
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
