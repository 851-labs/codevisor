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
///
/// Workspaces reorder with the system's long-press drag. Folders and
/// projects reorder from their headers: a long press lifts the group and
/// collapses it to its header, the drag moves it past the others, and the
/// drop commits the order (see `HomeAgentList+GroupDrag`).
struct HomeAgentList: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
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
  @State var groupDrag: GroupDrag?
  @State var headerFrames = HomeGroupHeaderFrames()
  @State var listFrame: CGRect = .zero
  @State var liftFeedback = 0

  var navigation: NavigationStore { environment.navigationStore }

  /// A folder, or a project when grouped by project: a section of
  /// workspaces that collapses and reorders from its header.
  struct SidebarGroup: Identifiable {
    let id: String
    let title: String
    let rows: [AgentSidebarRow]
    var folder: ServerNavigationFolder?
    var projectId: UUID?
  }

  var body: some View {
    // The projection isn't observed directly; the revision is what changes.
    let _ = navigation.revision
    let nodes = navigation.agentSidebar
    let groups = groups(of: nodes)
    let list = Group {
      if let selection {
        List(selection: selection) { content(nodes, groups: groups) }
      } else {
        List { content(nodes, groups: groups) }
      }
    }
    groupDragChrome(list.listStyle(.sidebar), groups: groups)
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

  private func groups(of nodes: [AgentSidebarNode]) -> [SidebarGroup] {
    nodes.compactMap { node in
      switch node {
      case .agent: nil
      case let .folder(folder, rows): SidebarGroup(id: folder.id, title: folder.name, rows: rows, folder: folder)
      case let .project(project, rows):
        SidebarGroup(id: "\(project.serverId):\(project.id)", title: project.name, rows: rows, projectId: project.id)
      }
    }
  }

  @ViewBuilder
  private func content(_ nodes: [AgentSidebarNode], groups: [SidebarGroup]) -> some View {
    let loose = nodes.compactMap { node -> AgentSidebarRow? in
      if case let .agent(row) = node { row } else { nil }
    }
    if !loose.isEmpty {
      Section {
        if showsLoose { outline(loose) }
      } header: {
        HomeAgentSectionHeader(title: "Workspaces", isExpanded: showsLoose) {
          withAnimation { showsLoose.toggle() }
        }
      }
    }
    ForEach(displayed(groups)) { group in
      Section {
        if isExpanded(group), groupDrag?.id != group.id { outline(group.rows) }
      } header: {
        groupHeader(group, in: groups)
      }
    }
  }

  private func outline(_ rows: [AgentSidebarRow]) -> some View {
    WorkspaceOutline(rows: rows, owner: nil, expanded: $expanded, isSelectable: selection != nil)
  }

  func isExpanded(_ group: SidebarGroup) -> Bool {
    if let folder = group.folder { return !folder.collapsed }
    return !collapsedProjects.contains(group.id)
  }

  /// A folder's collapse syncs to every device; a project's is this
  /// device's own.
  private func toggle(_ group: SidebarGroup) {
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

  /// A folder's actions are in a menu on its header: a long press there
  /// lifts the folder to reorder it.
  private func groupHeader(_ group: SidebarGroup, in groups: [SidebarGroup]) -> some View {
    draggableHeader(group, in: groups) {
      if let folder = group.folder {
        HomeAgentSectionHeader(title: group.title, isExpanded: isExpanded(group)) {
          toggle(group)
        } menu: {
          Button("Rename", systemImage: "pencil") {
            folderTitle = folder.name
            renamingFolder = folder
          }
          Button("Delete Folder…", systemImage: "trash", role: .destructive) {
            deleting = (folder, group.rows.map(\.id))
          }
        }
      } else {
        HomeAgentSectionHeader(title: group.title, isExpanded: isExpanded(group)) { toggle(group) }
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

/// A section's header: its title, a menu of its actions if it has any,
/// and a chevron that collapses it.
struct HomeAgentSectionHeader<MenuContent: View>: View {
  let title: String
  let isExpanded: Bool
  let toggle: () -> Void
  @ViewBuilder let menu: MenuContent

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
      if MenuContent.self != EmptyView.self {
        Menu {
          menu
        } label: {
          Image(systemName: "ellipsis")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 20)
            .contentShape(Rectangle().inset(by: -8))
        }
        .accessibilityLabel("\(title) Actions")
      }
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.primary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: 20, height: 20)
        .contentShape(Rectangle().inset(by: -8))
        .onTapGesture(perform: toggle)
        // Where the system draws a collapsible section's chevron, in line
        // with the rows' chevrons, past the header's own inset.
        .padding(.trailing, -13)
        .accessibilityHidden(true)
    }
    .textCase(nil)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { toggle() }
  }
}

extension HomeAgentSectionHeader where MenuContent == EmptyView {
  init(title: String, isExpanded: Bool, toggle: @escaping () -> Void) {
    self.init(title: title, isExpanded: isExpanded, toggle: toggle) { EmptyView() }
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
