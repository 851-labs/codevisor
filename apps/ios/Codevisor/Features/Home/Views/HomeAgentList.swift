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

/// The workspaces the user manages, as Notes lists folders: loose ones as
/// the page's own list, then a section per folder (or per project when
/// grouped that way), each section collapsing from its header. A workspace
/// with workspaces nested under it discloses them inline from its chevron;
/// tapping a workspace opens its page, where its tabs are.
///
/// Workspaces reorder with the system's long-press drag. Folders and
/// projects reorder from their headers: a long press lifts the group and
/// collapses it to its header, the drag moves it past the others, and the
/// drop commits the order. Let go without moving and a folder's menu opens
/// (see `HomeAgentList+GroupDrag`).
struct HomeAgentList: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
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
  @State var groupDrag: GroupDrag?
  /// The group whose header menu should open, and a count that changes
  /// each time it's asked for.
  @State var menuRequest: (id: String, token: Int)?
  @State var listFrame: CGRect = .zero
  @State var liftFeedback = 0
  @State var headerFrames = HomeGroupHeaderFrames()

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
    groupDragChrome(list.listStyle(.sidebar).contentMargins(.top, 12, for: .scrollContent), groups: groups)
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
    // Loose workspaces are the page's own list, without a header.
    if !loose.isEmpty {
      Section { outline(loose) }
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

  /// A folder's actions open from its header when it's held and let go
  /// without moving; moving it reorders it.
  private func groupHeader(_ group: SidebarGroup, in groups: [SidebarGroup]) -> some View {
    draggableHeader(group, in: groups, menu: menu(for: group)) {
      HomeAgentSectionHeader(title: group.title, isExpanded: isExpanded(group)) { toggle(group) }
    }
  }

  private func menu(for group: SidebarGroup) -> [HomeGroupHeaderAction] {
    guard let folder = group.folder else { return [] }
    return [
      HomeGroupHeaderAction(title: "Rename", systemImage: "pencil") {
        folderTitle = folder.name
        renamingFolder = folder
      },
      HomeGroupHeaderAction(title: "Delete Folder…", systemImage: "trash", isDestructive: true) {
        deleting = (folder, group.rows.map(\.id))
      },
    ]
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

/// A section's header: its title and a chevron that collapses it.
struct HomeAgentSectionHeader: View {
  let title: String
  let isExpanded: Bool
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.primary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: 20, height: 20)
        // Where the system draws a collapsible section's chevron, in line
        // with the rows' chevrons, past the header's own inset.
        .padding(.trailing, -13)
    }
    .textCase(nil)
    .contentShape(Rectangle())
    .onTapGesture(perform: toggle)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityAction { toggle() }
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
