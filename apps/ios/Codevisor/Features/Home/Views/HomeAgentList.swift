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

/// The agents the user manages, the way every client lists them: folders
/// and loose agents (or one section per project), each agent with its
/// subagents in a disclosure group. Tabs are not here; they live in each
/// agent's tab overview.
struct HomeAgentList: View {
  @Environment(AppEnvironment.self) private var environment
  let actions: HomeAgentListActions
  /// The split layout's selected workspace or chat. Present, the list is a
  /// native sidebar selection list; absent, it is the phone's grouped list.
  var selection: Binding<UUID?>? = nil

  @State private var expanded: Set<UUID> = []
  @State private var renamingFolder: ServerNavigationFolder?
  @State private var folderTitle = ""

  private var navigation: NavigationStore { environment.navigationStore }

  var body: some View {
    // The projection isn't observed directly; the revision is what changes.
    let _ = navigation.revision
    let nodes = navigation.agentSidebar
    Group {
      if let selection {
        List(selection: selection) { content(nodes) }
          .listStyle(.sidebar)
      } else {
        List { content(nodes) }
          .listStyle(.insetGrouped)
      }
    }
    .refreshable { await actions.refresh() }
    .alert("Rename Folder", isPresented: renamePresented) {
      TextField("Name", text: $folderTitle)
      Button("Rename") { commitFolderRename() }
      Button("Cancel", role: .cancel) { renamingFolder = nil }
    }
  }

  @ViewBuilder
  private func content(_ nodes: [AgentSidebarNode]) -> some View {
    switch navigation.sidebarGrouping {
    case .none:
      Section {
        ForEach(nodes) { node in
          switch node {
          case let .agent(row): agent(row)
          case let .folder(folder, rows): folderGroup(folder, rows: rows)
          case .project: EmptyView()
          }
        }
      }
    case .project:
      ForEach(nodes) { node in
        if case let .project(project, rows) = node {
          Section(project.name) {
            ForEach(rows) { agent($0) }
          }
        }
      }
    }
  }

  private func folderGroup(_ folder: ServerNavigationFolder, rows: [AgentSidebarRow]) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { !folder.collapsed },
        set: { expanded in
          guard let id = UUID(uuidString: folder.id) else { return }
          navigation.saveFolder(id: id, name: folder.name, position: folder.position, collapsed: !expanded)
        })
    ) {
      ForEach(rows) { agent($0) }
    } label: {
      Label(folder.name, systemImage: "folder")
    }
    .contextMenu {
      Button("Rename", systemImage: "pencil") {
        folderTitle = folder.name
        renamingFolder = folder
      }
      Button("Delete Folder", systemImage: "trash", role: .destructive) {
        if let id = UUID(uuidString: folder.id) { navigation.deleteFolder(id: id) }
      }
    }
  }

  @ViewBuilder
  private func agent(_ row: AgentSidebarRow) -> some View {
    if navigation.showsSubagents, !row.subagents.isEmpty {
      DisclosureGroup(
        isExpanded: Binding(
          get: { expanded.contains(row.id) },
          set: { if $0 { expanded.insert(row.id) } else { expanded.remove(row.id) } })
      ) {
        ForEach(row.subagents) { subagent($0) }
      } label: {
        agentLabel(row)
      }
    } else {
      agentLabel(row)
    }
  }

  private func agentLabel(_ row: AgentSidebarRow) -> some View {
    rowButton(tag: row.id, open: { actions.open(row.id, nil) }) {
      HStack(spacing: 10) {
        HomeStatusIndicator(status: HomeSessionStatus(row.status))
          .frame(width: 14)
        VStack(alignment: .leading, spacing: 2) {
          Text(row.title).lineLimit(1)
          if let detail = detail(row) {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        if navigation.showsSubagents, let rollup = row.rollup {
          Text("\(rollup.finished)/\(rollup.total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(rollup.status.isBlocked ? .orange : .secondary)
            .accessibilityLabel("\(rollup.finished) of \(rollup.total) subagents finished")
        }
      }
    }
    .swipeActions(edge: .trailing) {
      Button("Archive", systemImage: "archivebox", role: .destructive) { actions.archive(row.id) }
    }
    .contextMenu { agentMenu(row) }
  }

  private func subagent(_ subagent: AgentSidebarSubagent) -> some View {
    rowButton(
      tag: subagent.id,
      open: {
        actions.open(subagent.workspaceId, subagent.kind == .chat ? subagent.id : nil)
      }
    ) {
      HStack(spacing: 10) {
        HomeStatusIndicator(status: HomeSessionStatus(subagent.status))
          .frame(width: 14)
        VStack(alignment: .leading, spacing: 2) {
          Text(subagent.title).font(.subheadline).lineLimit(1)
          if let via = subagent.via {
            Text("via \(via)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
    }
    .contextMenu {
      if subagent.kind == .workspace {
        Button("Move to Sidebar", systemImage: "sidebar.left") { promote(subagent.workspaceId) }
        Button("Archive", systemImage: "archivebox", role: .destructive) { actions.archive(subagent.workspaceId) }
      }
    }
  }

  /// A split row is tagged for the native selection; a phone row is a
  /// button that pushes.
  @ViewBuilder
  private func rowButton<Label: View>(
    tag: UUID, open: @escaping () -> Void, @ViewBuilder label: () -> Label
  )
    -> some View
  {
    if selection != nil {
      label().tag(tag)
    } else {
      Button(action: open) { label().contentShape(Rectangle()) }
        .buttonStyle(.plain)
    }
  }

  @ViewBuilder
  private func agentMenu(_ row: AgentSidebarRow) -> some View {
    Button("Rename", systemImage: "pencil") { actions.rename(row.id) }
    if navigation.sidebarGrouping == .none {
      Menu("Move to Folder", systemImage: "folder") {
        ForEach(navigation.folders, id: \.id) { folder in
          Button(folder.name) { file(row.id, into: UUID(uuidString: folder.id)) }
        }
        Button("New Folder", systemImage: "folder.badge.plus") { newFolder(filing: row.id) }
        if environment.workspaces.workspace(id: row.id)?.folderId != nil {
          Button("Remove from Folder") { file(row.id, into: nil) }
        }
      }
    }
    let owned = row.subagents.filter { $0.kind == .workspace }.count
    Button(
      owned == 0 ? "Archive" : "Archive with \(owned) Subagent\(owned == 1 ? "" : "s")",
      systemImage: "archivebox", role: .destructive
    ) {
      actions.archive(row.id)
    }
  }

  private func detail(_ row: AgentSidebarRow) -> String? {
    let machine = environment.machines.machine(for: row.serverId).flatMap { $0.isLocal ? nil : $0.name }
    let parts = [row.branch, machine].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func file(_ workspaceId: UUID, into folder: UUID?) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    navigation.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .folder(folder)), machineId: workspace.serverId)
  }

  private func promote(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    navigation.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .owner(nil)), machineId: workspace.serverId)
  }

  private func newFolder(filing workspaceId: UUID?) {
    let id = HomeAgentListOptions.createFolder(in: navigation)
    if let workspaceId { file(workspaceId, into: id) }
    if let folder = navigation.folders.first(where: { UUID(uuidString: $0.id) == id }) {
      folderTitle = folder.name
      renamingFolder = folder
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

/// The list's view options, for the navigation bar: grouping, whether
/// subagents show, and a new folder. All of it syncs to every device.
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
      Toggle(
        "Show Subagents",
        isOn: Binding(
          get: { navigation.showsSubagents },
          set: { navigation.setSetting(NavigationStore.sidebarSubagentsKey, value: $0 ? "nested" : "hidden") }))
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
