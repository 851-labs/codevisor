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

/// The workspaces the user manages, in one list as the Mac's sidebar has
/// them: loose workspaces and folders (or projects, when grouped that way)
/// in their order, a folder disclosing the workspaces filed in it. A
/// workspace with workspaces nested under it discloses them inline from
/// its chevron; tapping a workspace opens its page, where its tabs are.
///
/// Every row reorders with the system's long-press drag, and since they're
/// one list a workspace can be dragged into a folder, between folders or
/// out of them (see `HomeSidebarDrop`).
struct HomeAgentList: View {
  @Environment(AppEnvironment.self) private var environment
  let actions: HomeAgentListActions
  /// The split layout's selected workspace. Present, the rows are a native
  /// sidebar selection; absent, each row pushes its page.
  var selection: Binding<UUID?>? = nil

  @State private var expanded: Set<UUID> = []
  @State private var collapsedProjects: Set<String> = []
  @State private var renamingFolder: ServerNavigationFolder?
  @State private var folderTitle = ""
  /// The folder being deleted, with the agents filed in it.
  @State private var deleting: (folder: ServerNavigationFolder, agents: [UUID])?

  private var navigation: NavigationStore { environment.navigationStore }

  var body: some View {
    // The projection isn't observed directly; the revision is what changes.
    let _ = navigation.revision
    let entries = HomeSidebarEntry.entries(
      navigation.agentSidebar, expandedWorkspaces: expanded, isExpanded: isExpanded)
    Group {
      if let selection {
        List(selection: selection) { content(entries) }
      } else {
        List { content(entries) }
      }
    }
    .listStyle(.sidebar)
    .contentMargins(.top, 12, for: .scrollContent)
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

  @ViewBuilder
  private func content(_ entries: [HomeSidebarEntry]) -> some View {
    if !entries.isEmpty {
      Section {
        ForEach(entries) { entry in
          switch entry.kind {
          case let .group(group):
            HomeFolderRow(group: group, isExpanded: isExpanded(group)) { toggle(group) }
              .contextMenu { folderMenu(group) }
          case let .agent(row, owner):
            WorkspaceOutlineRow(
              row: row, owner: owner, expanded: $expanded, isSelectable: selection != nil, depth: entry.depth)
          }
        }
        .onMove { source, destination in move(entries, from: source, to: destination) }
      }
    }
  }

  @ViewBuilder
  private func folderMenu(_ group: HomeSidebarGroup) -> some View {
    if let folder = group.folder {
      Button("Rename", systemImage: "pencil") {
        folderTitle = folder.name
        renamingFolder = folder
      }
      Button("Delete Folder…", systemImage: "trash", role: .destructive) {
        deleting = (folder, group.rows.map(\.id))
      }
    }
  }

  // MARK: - Moving

  /// A row dropped somewhere new. A folder moves among the top-level rows,
  /// a project among the projects. A workspace nested under another stays
  /// among its siblings when dropped beside one; otherwise a workspace is
  /// filed where it lands: into a folder, between folders, or out of them.
  /// It can't change projects, so a drop in another project puts it back.
  private func move(_ entries: [HomeSidebarEntry], from source: IndexSet, to destination: Int) {
    guard let from = source.first, entries.indices.contains(from) else { return }
    let moved = entries[from]
    let openGroups = Set(entries.compactMap { $0.group.flatMap { isExpanded($0) ? $0.id : nil } })
    let drop = HomeSidebarDrop(entries, from: from, to: destination, openGroups: openGroups)
    switch moved.kind {
    case let .group(group):
      if let folder = group.folder, let id = UUID(uuidString: folder.id) {
        let (lower, upper) = drop.neighbors(in: nil)
        navigation.moveFolder(id, after: lower, before: upper)
      } else if let projectId = group.projectId {
        let projects = drop.rest.compactMap { $0.group?.projectId }
        navigation.moveProject(projectId, to: drop.count { $0.group != nil }, among: projects)
      }
    case let .agent(row, owner):
      if let owner, drop.touches(where: { $0.owner?.id == owner.id }) {
        let isSibling = { (entry: HomeSidebarEntry) in entry.owner?.id == owner.id }
        navigation.moveNestedAgent(
          row.id, to: drop.count(where: isSibling), among: drop.rest.filter(isSibling).compactMap(\.agent?.id))
        return
      }
      let groupId = drop.groupId(movingFrom: moved.groupId)
      let folder: UUID?
      switch navigation.sidebarGrouping {
      case .none:
        folder = groupId.flatMap(UUID.init(uuidString:))
      case .project:
        // Grouped by project, its folder stays as it was.
        guard let groupId, groupId == moved.groupId else { return }
        folder = environment.workspaces.workspace(id: row.id)?.folderId
      }
      let (lower, upper) = drop.neighbors(in: groupId)
      navigation.fileAgent(row.id, intoFolder: folder, after: lower, before: upper)
    }
  }

  // MARK: - Groups

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

  private func isExpanded(_ group: HomeSidebarGroup) -> Bool {
    if let folder = group.folder { return !folder.collapsed }
    return !collapsedProjects.contains(group.id)
  }

  /// A folder's collapse syncs to every device; a project's is this
  /// device's own.
  private func toggle(_ group: HomeSidebarGroup) {
    withAnimation {
      if let folder = group.folder, let id = UUID(uuidString: folder.id) {
        navigation.saveFolder(id: id, name: folder.name, position: folder.position, collapsed: !folder.collapsed)
      } else if collapsedProjects.contains(group.id) {
        collapsedProjects.remove(group.id)
      } else {
        collapsedProjects.insert(group.id)
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
  @State private var namingFolder = false
  @State private var folderName = ""

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
        Button("New Folder", systemImage: "folder.badge.plus") {
          folderName = ""
          namingFolder = true
        }
      }
    } label: {
      Label("View Options", systemImage: "line.3.horizontal.decrease")
    }
    // A folder is made once it has a name; cancelling makes none.
    .alert("New Folder", isPresented: $namingFolder) {
      TextField("Name", text: $folderName)
      Button("Create") {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = Self.createFolder(named: name, in: navigation)
      }
      .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Cancel", role: .cancel) {}
    }
  }

  /// A new folder at the top of the list.
  @MainActor
  static func createFolder(named name: String, in navigation: NavigationStore) -> UUID {
    let id = UUID()
    let first = navigation.agentSidebar.first.map { node -> String in
      switch node {
      case let .agent(row): row.position
      case let .folder(folder, _): folder.position
      case .project: ""
      }
    }
    let position = WorkspacePosition.between(nil, first, id: id) ?? "0000000000008"
    navigation.saveFolder(id: id, name: name, position: position)
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
