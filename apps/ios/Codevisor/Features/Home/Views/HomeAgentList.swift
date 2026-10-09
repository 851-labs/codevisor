import CodevisorCore
import CodevisorUI
import SwiftUI

/// What the agent list asks its owner to do.
struct HomeAgentListActions {
  /// Opens a workspace on a chat (its own, when nil).
  var open: (UUID, UUID?) -> Void = { _, _ in }
  var rename: (UUID) -> Void = { _ in }
  var archive: (UUID) -> Void = { _ in }
  var didSelectInSplit: () -> Void = {}
  var refresh: () async -> Void = {}
}

/// The workspaces the user manages, as Notes lists folders: loose ones in a
/// section of their own, then a section per folder (or per project when
/// grouped that way), each section collapsing from its header. A workspace
/// with workspaces nested under it discloses them inline from its chevron;
/// tapping a workspace opens its page, where its tabs are.
struct HomeAgentList: View {
  @Environment(AppEnvironment.self) private var environment
  let actions: HomeAgentListActions
  /// The split layout's selected workspace. Present, the rows are a native
  /// sidebar selection; absent, each row pushes its page.
  var selection: Binding<UUID?>? = nil

  @State private var expanded: Set<UUID> = []
  @State private var showsLoose = true
  @State private var collapsedProjects: Set<String> = []
  @State private var renamingFolder: ServerNavigationFolder?
  @State private var folderTitle = ""
  /// The folder being deleted, with the agents filed in it.
  @State private var deleting: (folder: ServerNavigationFolder, agents: [UUID])?

  private var navigation: NavigationStore { environment.navigationStore }

  var body: some View {
    // The projection isn't observed directly; the revision is what changes.
    let _ = navigation.revision
    let nodes = navigation.agentSidebar
    Group {
      if let selection {
        List(selection: selection) { content(nodes) }
      } else {
        List { content(nodes) }
      }
    }
    .listStyle(.sidebar)
    .refreshable { await actions.refresh() }
    .onChange(of: selection?.wrappedValue, initial: true) { _, id in revealAncestors(of: id) }
    .alert("Rename Folder", isPresented: renamePresented) {
      TextField("Name", text: $folderTitle)
      Button("Rename") { commitFolderRename() }
      Button("Cancel", role: .cancel) { renamingFolder = nil }
    }
    .confirmationDialog(
      deleting.map { "Delete “\($0.folder.name)”?" } ?? "",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      if let deleting {
        let count = deleting.agents.count
        Button("Delete Folder") { delete(deleting.folder, archiving: []) }
        if count > 0 {
          Button("Delete Folder and \(count) Workspace\(count == 1 ? "" : "s")", role: .destructive) {
            delete(deleting.folder, archiving: deleting.agents)
          }
        }
        Button("Cancel", role: .cancel) {}
      }
    }
  }

  /// A workspace selected from elsewhere (a page's nested workspace) shows
  /// in place: the workspaces it nests under disclose down to it.
  private func revealAncestors(of id: UUID?) {
    var parent = id.flatMap { environment.workspaces.workspace(id: $0)?.parentWorkspaceId }
    while let next = parent {
      expanded.insert(next)
      parent = environment.workspaces.workspace(id: next)?.parentWorkspaceId
    }
  }

  private func delete(_ folder: ServerNavigationFolder, archiving agents: [UUID]) {
    for id in agents { actions.archive(id) }
    if let id = UUID(uuidString: folder.id) { navigation.deleteFolder(id: id) }
  }

  @ViewBuilder
  private func content(_ nodes: [AgentSidebarNode]) -> some View {
    switch navigation.sidebarGrouping {
    case .none:
      let loose = nodes.compactMap { node -> AgentSidebarRow? in
        if case let .agent(row) = node { row } else { nil }
      }
      if !loose.isEmpty {
        Section("Workspaces", isExpanded: $showsLoose) { rows(loose) }
      }
      ForEach(nodes) { node in
        if case let .folder(folder, rows) = node { folderSection(folder, rows: rows) }
      }
    case .project:
      ForEach(nodes) { node in
        if case let .project(project, rows) = node {
          let key = "\(project.serverId):\(project.id)"
          Section(
            project.name,
            isExpanded: Binding(
              get: { !collapsedProjects.contains(key) },
              set: { if $0 { collapsedProjects.remove(key) } else { collapsedProjects.insert(key) } })
          ) {
            self.rows(rows)
          }
        }
      }
    }
  }

  private func rows(_ rows: [AgentSidebarRow]) -> some View {
    ForEach(rows) { row in
      WorkspaceOutlineRow(row: row, owner: nil, expanded: $expanded, isSelectable: selection != nil)
    }
  }

  /// A folder is a section of its own, collapsing from its header like a
  /// Notes account; collapsed or not syncs to every device.
  private func folderSection(_ folder: ServerNavigationFolder, rows: [AgentSidebarRow]) -> some View {
    Section(
      isExpanded: Binding(
        get: { !folder.collapsed },
        set: { expanded in
          guard let id = UUID(uuidString: folder.id) else { return }
          navigation.saveFolder(id: id, name: folder.name, position: folder.position, collapsed: !expanded)
        })
    ) {
      self.rows(rows)
    } header: {
      Text(folder.name)
        .contextMenu {
          Button("Rename", systemImage: "pencil") {
            folderTitle = folder.name
            renamingFolder = folder
          }
          Button("Delete Folder…", systemImage: "trash", role: .destructive) {
            deleting = (folder, rows.map(\.id))
          }
        }
    }
  }

  private var renamePresented: Binding<Bool> {
    Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })
  }

  private func commitFolderRename() {
    guard let folder = renamingFolder, let id = UUID(uuidString: folder.id) else { return }
    renamingFolder = nil
    let name = folderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    navigation.saveFolder(id: id, name: name, position: folder.position, collapsed: folder.collapsed)
  }
}

/// The list's view options, for the navigation bar: grouping and a new
/// folder. Both sync to every device.
struct HomeAgentListOptions: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    let navigation = environment.navigationStore
    Menu {
      Section("Group By") {
        Picker(
          "Group By",
          selection: Binding(
            get: { navigation.sidebarGrouping },
            set: { navigation.setSetting(NavigationStore.sidebarGroupingKey, value: $0.rawValue) })
        ) {
          Text("None").tag(AgentSidebarGrouping.none)
          Text("Project").tag(AgentSidebarGrouping.project)
        }
      }
      if navigation.sidebarGrouping == .none {
        Button("New Folder", systemImage: "folder.badge.plus") { _ = Self.createFolder(in: navigation) }
      }
    } label: {
      Label("View Options", systemImage: "line.3.horizontal.decrease")
    }
  }

  /// A new folder at the top of the list.
  @MainActor
  static func createFolder(in navigation: NavigationStore) -> UUID {
    let id = UUID()
    let first = navigation.agentSidebar.first.map { node -> String in
      switch node {
      case let .agent(row): row.position
      case let .folder(folder, _): folder.position
      case .project: ""
      }
    }
    let position = WorkspacePosition.between(nil, first, id: id) ?? "0000000000008"
    navigation.saveFolder(id: id, name: "New Folder", position: position)
    return id
  }
}

extension HomeSessionStatus {
  init(_ status: AgentStatus) {
    switch status {
    case .idle: self = .idle
    case .unread: self = .unread
    case .working: self = .inProgress
    case .waiting: self = .actionRequired
    case .errored: self = .error
    }
  }
}
