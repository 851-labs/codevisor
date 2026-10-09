import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// What the agent list asks its owner to do.
struct HomeAgentListActions {
  /// Opens a workspace on a chat (its own, when nil).
  var open: (UUID, UUID?) -> Void = { _, _ in }
  var rename: (UUID) -> Void = { _ in }
  var archive: (UUID) -> Void = { _ in }
  var didSelectInSplit: () -> Void = {}
  var refresh: () async -> Void = {}
}

/// The workspaces the user manages, as Notes lists folders and notes: a
/// Folders list (projects, when grouped that way), each folder disclosing
/// its workspaces, then the workspaces in no folder. A workspace with
/// workspaces nested under it discloses them; tapping one opens its page.
/// Dragging a workspace onto a folder files it there, and rows reorder by
/// dragging within their list (see `HomeAgentCollection`).
struct HomeAgentList: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.workspaceRowActions) private var rowActions
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
    HomeAgentCollection(
      environment: environment,
      model: { [navigation] in HomeListModel(nodes: navigation.agentSidebar, grouping: navigation.sidebarGrouping) },
      expandedWorkspaces: expanded,
      isExpanded: isExpanded,
      selection: selection?.wrappedValue,
      isSelectionList: selection != nil,
      actions: collectionActions
    )
    .ignoresSafeArea(.container, edges: .vertical)
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

  private var collectionActions: HomeAgentCollectionActions {
    HomeAgentCollectionActions(
      open: { row in rowActions.openPage(row.serverId, row.id) },
      select: { id in selection?.wrappedValue = id },
      setWorkspaceExpanded: { id, isExpanded in
        if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
      },
      setGroupExpanded: { group, isExpanded in setExpanded(group, isExpanded) },
      drop: { item, drop in perform(drop, moving: item) },
      workspaceMenu: { row, owner in workspaceMenu(row, owner: owner) },
      groupMenu: { group in folderMenu(group) },
      archive: actions.archive,
      refresh: actions.refresh
    )
  }

  // MARK: - Moving

  /// A row dropped somewhere new, filed or placed there in the store.
  private func perform(_ drop: HomeListDrop, moving item: HomeListItem) {
    let model = HomeListModel(nodes: navigation.agentSidebar, grouping: navigation.sidebarGrouping)
    switch (item, drop) {
    case let (.workspace(id), .intoGroup(groupId)):
      let last = model.group(groupId)?.rows.last { $0.id != id }?.position
      navigation.fileAgent(id, intoFolder: UUID(uuidString: groupId), after: last, before: nil)
    case let (.workspace(id), .inGroup(groupId, lower, upper)):
      // Grouped by project, its folder stays as it was.
      let folder =
        model.grouping == .none ? UUID(uuidString: groupId) : environment.workspaces.workspace(id: id)?.folderId
      navigation.fileAgent(id, intoFolder: folder, after: lower, before: upper)
    case let (.workspace(id), .loose(lower, upper)):
      navigation.fileAgent(id, intoFolder: nil, after: lower, before: upper)
    case let (.workspace(id), .nested(_, index, siblings)):
      navigation.moveNestedAgent(id, to: index, among: siblings)
    case let (.group(groupId), .folder(lower, upper)):
      if let id = UUID(uuidString: groupId) { navigation.moveFolder(id, after: lower, before: upper) }
    case let (.group(groupId), .project(index, projects)):
      if let projectId = model.group(groupId)?.projectId {
        navigation.moveProject(projectId, to: index, among: projects)
      }
    default:
      break
    }
  }

  // MARK: - Menus

  private func workspaceMenu(_ row: AgentSidebarRow, owner: AgentSidebarRow?) -> UIMenu {
    var items: [UIMenuElement] = [
      UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in actions.rename(row.id) }
    ]
    if let owner {
      items.append(
        UIAction(title: "Move Out of “\(owner.title)”", image: UIImage(systemName: "arrow.up.left")) { _ in
          change(row.id, .owner(nil))
        })
    } else if navigation.sidebarGrouping == .none, !navigation.folders.isEmpty {
      var folders: [UIMenuElement] = navigation.folders.map { folder in
        UIAction(title: folder.name) { _ in change(row.id, .folder(UUID(uuidString: folder.id))) }
      }
      if environment.workspaces.workspace(id: row.id)?.folderId != nil {
        folders.append(
          UIMenu(
            options: .displayInline,
            children: [UIAction(title: "Remove from Folder") { _ in change(row.id, .folder(nil)) }]))
      }
      items.append(UIMenu(title: "Move to Folder", image: UIImage(systemName: "folder"), children: folders))
    }
    let owned = row.children.count
    items.append(
      UIAction(
        title: owned == 0 ? "Archive" : "Archive with \(owned) Workspace\(owned == 1 ? "" : "s")",
        image: UIImage(systemName: "archivebox"), attributes: .destructive
      ) { _ in actions.archive(row.id) })
    return UIMenu(children: items)
  }

  private func folderMenu(_ group: HomeSidebarGroup) -> UIMenu? {
    guard let folder = group.folder else { return nil }
    return UIMenu(children: [
      UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in
        folderTitle = folder.name
        renamingFolder = folder
      },
      UIAction(title: "Delete Folder…", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
        deleting = (folder, group.rows.map(\.id))
      },
    ])
  }

  private func change(_ id: UUID, _ change: WorkspaceHierarchyChange) {
    guard let workspace = environment.workspaces.workspace(id: id) else { return }
    navigation.enqueue(.updateWorkspaceHierarchy(workspaceId: id, change: change), machineId: workspace.serverId)
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

  /// A folder's disclosure syncs to every device; a project's is this
  /// device's own.
  private func setExpanded(_ group: HomeSidebarGroup, _ isExpanded: Bool) {
    if let folder = group.folder, let id = UUID(uuidString: folder.id) {
      navigation.saveFolder(id: id, name: folder.name, position: folder.position, collapsed: !isExpanded)
    } else if isExpanded {
      collapsedProjects.remove(group.id)
    } else {
      collapsedProjects.insert(group.id)
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
