import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  @State private var serverId: String
  let onAdded: (Project) -> Void

  @State private var recommendations: [ProjectRecommendation]?
  @State private var loadError: String?
  @State private var selectedPath: String?
  @State private var showingLocalImporter = false
  @State private var showingRemoteBrowser = false
  @State private var showingGitClone = false

  init(serverId: String, onAdded: @escaping (Project) -> Void) {
    _serverId = State(initialValue: serverId)
    self.onAdded = onAdded
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

  private var isTargetReady: Bool {
    environment.machines.availability(for: serverId) == .ready
  }

  private var visibleRecommendations: [ProjectRecommendation] {
    let registered = environment.projectList.registeredFolderPaths(serverId: serverId)
    return (recommendations ?? []).filter {
      !registered.contains($0.folderURL.standardizedFileURL.path)
    }
  }

  private var selectedRecommendation: ProjectRecommendation? {
    visibleRecommendations.first { $0.id == selectedPath }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      suggestions
      footer
    }
    .padding(20)
    .frame(width: 480)
    .task(id: "\(serverId):\(isTargetReady)") { await load() }
    .fileImporter(isPresented: $showingLocalImporter, allowedContentTypes: [.folder]) { result in
      if case let .success(url) = result { add(url) }
    }
    .fileDialogDefaultDirectory(FileManager.default.homeDirectoryForCurrentUser)
    .fileDialogConfirmationLabel("Add Project")
    .sheet(isPresented: $showingRemoteBrowser) {
      RemoteDirectoryBrowserSheet(client: client, machineName: machineName) { path in
        add(URL(fileURLWithPath: path))
      }
    }
    .sheet(isPresented: $showingGitClone) {
      GitCloneSheet(client: client, machineName: machineName, serverId: serverId) { project in
        onAdded(project)
        dismiss()
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Add Project")
        .font(.headline)
      Spacer(minLength: 12)
      if environment.machines.allMachines.count > 1 {
        Picker("Machine", selection: machineSelection) {
          ForEach(environment.machines.allMachines) { machine in
            Text(machine.name).tag(machine.id)
              .disabled(environment.machines.availability(for: machine.id) != .ready)
          }
        }
        .labelsHidden()
        .fixedSize()
        .help("The machine the project's folder is on")
      }
    }
  }

  private var suggestions: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
        ForEach(visibleRecommendations) { recommendation in
          RecentFolderTile(
            recommendation: recommendation,
            isLocal: machine?.isLocal == true,
            isSelected: recommendation.id == selectedPath,
            select: { selectedPath = recommendation.id },
            add: { add(recommendation.folderURL) }
          )
        }
      }
      .padding(8)
    }
    .frame(height: 216)
    .frame(maxWidth: .infinity)
    .overlay { suggestionsPlaceholder }
    .background(.fill.quinary, in: .rect(cornerRadius: 10))
    .contentShape(.rect)
    .onTapGesture { selectedPath = nil }
  }

  @ViewBuilder
  private var suggestionsPlaceholder: some View {
    if !isTargetReady {
      placeholder("\(machineName) Is Unavailable")
    } else if recommendations == nil, loadError != nil {
      VStack(spacing: 8) {
        placeholder("Couldn't Load Recent Folders")
        Button("Try Again") { Task { await load() } }
          .controlSize(.small)
      }
    } else if recommendations == nil {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Finding Recent Folders")
    } else if visibleRecommendations.isEmpty {
      placeholder("No Recent Folders")
    }
  }

  private func placeholder(_ title: String) -> some View {
    Text(title)
      .font(.callout)
      .foregroundStyle(.secondary)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button("Choose Folder…", action: chooseFolder)
      Button("Clone Repository…") { showingGitClone = true }
      Spacer()
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Add") {
        if let selectedRecommendation { add(selectedRecommendation.folderURL) }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(selectedRecommendation == nil)
    }
    .disabled(!isTargetReady)
  }

  private var machineSelection: Binding<String> {
    Binding(
      get: { serverId },
      set: { newValue in
        serverId = newValue
        selectedPath = nil
        loadError = nil
        recommendations = environment.cachedRecommendedProjects(serverId: newValue)
      }
    )
  }

  private func chooseFolder() {
    if machine?.isLocal == true {
      showingLocalImporter = true
    } else {
      showingRemoteBrowser = true
    }
  }

  private func load() async {
    let serverId = serverId
    if recommendations == nil {
      recommendations = environment.cachedRecommendedProjects(serverId: serverId)
    }
    guard isTargetReady else { return }
    do {
      let loaded = try await environment.recommendedProjects(serverId: serverId)
      guard !Task.isCancelled, self.serverId == serverId else { return }
      recommendations = loaded
      loadError = nil
    } catch {
      guard !Task.isCancelled, self.serverId == serverId else { return }
      loadError = serverErrorMessage(error)
    }
  }

  private func add(_ url: URL) {
    guard isTargetReady else { return }
    let serverId = serverId
    let client = client
    let projectList = environment.projectList
    let onAdded = onAdded
    dismiss()
    Task {
      onAdded(await projectList.addProject(folderURL: url, serverId: serverId, client: client))
    }
  }
}

private struct RecentFolderTile: View {
  let recommendation: ProjectRecommendation
  let isLocal: Bool
  let isSelected: Bool
  let select: () -> Void
  let add: () -> Void

  var body: some View {
    VStack(spacing: 4) {
      Image(nsImage: icon)
        .resizable()
        .frame(width: 48, height: 48)
        .padding(4)
        .background(
          isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear),
          in: .rect(cornerRadius: 6)
        )
      Text(recommendation.name)
        .font(.callout)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .truncationMode(.middle)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 4)
        .background(
          isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
          in: .rect(cornerRadius: 4)
        )
    }
    .frame(width: 96, height: 100, alignment: .top)
    .padding(.vertical, 4)
    .contentShape(.rect)
    .onTapGesture(perform: select)
    .simultaneousGesture(TapGesture(count: 2).onEnded(add))
    .help(recommendation.folderURL.path)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(recommendation.name)
    .accessibilityHint(recommendation.folderURL.path)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction(named: "Add Project", add)
    .accessibilityAction(.default, select)
  }

  private var icon: NSImage {
    isLocal
      ? NSWorkspace.shared.icon(forFile: recommendation.folderURL.path)
      : NSWorkspace.shared.icon(for: .folder)
  }
}

#Preview("Add Project") {
  NewProjectSheet(serverId: "local") { _ in }
    .environment(AppEnvironment.preview())
}
