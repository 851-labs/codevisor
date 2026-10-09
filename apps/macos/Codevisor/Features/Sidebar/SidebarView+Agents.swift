import CodevisorCore
import CodevisorUI
import SwiftUI

/// The sidebar: one row per agent the user manages -- the chat row it always
/// had, without workspace headers -- grouped the way the user chose: folders
/// and loose agents, or projects. Agents an agent owns (subagents with
/// workspaces of their own) nest under it, indented, as deep as they go;
/// dragging one out of its owner makes it independent. Grouping, folders,
/// order and ownership are shared by every device.
extension SidebarView {
  var agentNodes: [AgentSidebarNode] {
    // The projection isn't observed directly; the revision is what changes.
    _ = environment.navigationStore.revision
    return environment.navigationStore.agentSidebar
  }

  func agentList(_ nodes: [AgentSidebarNode]) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      agentListHeader
      ForEach(nodes) { node in
        nodeView(node).transition(.opacity)
      }
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: nodes.map(\.id))
    .overlay { GeometryReader { agentDragOverlay(in: $0) } }
    .alert("Rename Folder", isPresented: folderRenamePresented) {
      TextField("Name", text: $folderRenameTitle)
      Button("Rename") { commitFolderRename() }
      Button("Cancel", role: .cancel) { renamingFolder = nil }
    }
  }

  /// "Agents" and the view options, like Finder's sidebar section titles.
  private var agentListHeader: some View {
    let navigation = environment.navigationStore
    return HStack(spacing: 4) {
      Text("Agents")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      Spacer()
      Menu {
        Picker(
          "Grouping",
          selection: Binding(
            get: { navigation.sidebarGrouping },
            set: { navigation.setSetting(NavigationStore.sidebarGroupingKey, value: $0.rawValue) })
        ) {
          Text("None").tag(AgentSidebarGrouping.none)
          Text("Project").tag(AgentSidebarGrouping.project)
        }
        Divider()
        Button("New Folder", action: { createFolder(filing: nil) })
          .disabled(navigation.sidebarGrouping != .none)
      } label: {
        Image(systemName: "line.3.horizontal.decrease")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("View Options")
      .accessibilityLabel("Sidebar View Options")
    }
    .padding(.horizontal, 6)
    .padding(.top, 10)
    .padding(.bottom, 2)
  }

  @ViewBuilder
  private func nodeView(_ node: AgentSidebarNode) -> some View {
    switch node {
    case let .agent(row):
      agentTree(row)
    case let .folder(folder, rows):
      VStack(alignment: .leading, spacing: 1) {
        AgentSidebarSectionHeader(
          title: folder.name, systemImage: "folder", isCollapsed: folder.collapsed,
          onToggle: { toggleFolder(folder) }
        )
        .contextMenu {
          Button("Rename…") { beginFolderRename(folder) }
          Button("Delete Folder", role: .destructive) {
            if let id = UUID(uuidString: folder.id) { environment.navigationStore.deleteFolder(id: id) }
          }
        }
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: { frame in
          if let id = UUID(uuidString: folder.id) { agentFrames.folders[id] = frame }
        }
        if !folder.collapsed {
          ForEach(rows) { row in
            agentTree(row).padding(.leading, 10)
          }
        }
      }
    case let .project(project, rows):
      let key = "\(project.serverId):\(project.id)"
      VStack(alignment: .leading, spacing: 1) {
        AgentSidebarSectionHeader(
          title: project.name, systemImage: "folder.badge.gearshape",
          isCollapsed: collapsedProjects.contains(key),
          onToggle: {
            if collapsedProjects.contains(key) {
              collapsedProjects.remove(key)
            } else {
              collapsedProjects.insert(key)
            }
          }
        )
        .draggable("project:\(project.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
          dropProjects(items, before: project)
        }
        if !collapsedProjects.contains(key) {
          ForEach(rows) { row in agentTree(row) }
        }
      }
    }
  }

  /// An agent and, indented under it, the agents it owns.
  private func agentTree(_ row: AgentSidebarRow) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(AgentSidebarEntry.flattening(row)) { entry in
        agentBlock(entry.row, owner: entry.owner)
          .padding(.leading, CGFloat(entry.depth) * 16)
      }
    }
  }

  /// The agent's row, drawn from its own chat: the chat's live status or
  /// harness icon, its title, and a close button that archives it.
  private func agentBlock(_ row: AgentSidebarRow, owner: AgentSidebarRow?) -> some View {
    let workspace = environment.workspaces.workspace(id: row.id)
    let home = workspace.flatMap { environment.navigationStore.homeChatId(of: $0) }
      .flatMap { list.session($0, serverId: row.serverId) }
    return SidebarWorkspaceTabRow(
      title: row.title, kind: .chat, isAgentOwned: false, chatSession: home, store: store,
      isSelected: selectedWorkspaceId() == row.id, isReordering: false, titleFont: itemTitleFont,
      onActivate: { openWorkspace(row.id) },
      onClose: { archive(row.id) },
      onRename: { beginRename(row.id) }
    )
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: {
      agentFrames.rows[row.id] = $0
    }
    .opacity(agentDrag?.id == row.id ? 0.4 : 1)
    .simultaneousGesture(agentDragGesture(row))
    .contextMenu {
      if let owner {
        Button("Move Out of “\(owner.title)”") { setOwner(of: row.id, to: nil) }
        Divider()
      }
      agentMenu(row)
    }
  }

  private func beginRename(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    workspaceRenameTitle = workspace.name
    renamingWorkspace = workspace
  }

  @ViewBuilder
  private func agentMenu(_ row: AgentSidebarRow) -> some View {
    let navigation = environment.navigationStore
    Button("Rename…") { beginRename(row.id) }
    if navigation.sidebarGrouping == .none {
      Menu("Move to Folder") {
        ForEach(navigation.folders, id: \.id) { folder in
          Button(folder.name) { file(row.id, into: UUID(uuidString: folder.id)) }
        }
        if !navigation.folders.isEmpty { Divider() }
        Button("New Folder") { createFolder(filing: row.id) }
        if environment.workspaces.workspace(id: row.id)?.folderId != nil {
          Button("Remove from Folder") { file(row.id, into: nil) }
        }
      }
    }
    Divider()
    let owned = row.subagents.filter { $0.kind == .workspace }.count
    Button(owned == 0 ? "Archive" : "Archive with \(owned) Subagent\(owned == 1 ? "" : "s")") {
      archive(row.id)
    }
  }

  // MARK: - Selection

  private func selectedWorkspaceId() -> UUID? {
    switch selection {
    case let .session(_, sessionId): environment.workspaces.workspaceId(forSession: sessionId)
    case let .workspace(_, id): id
    case .newChat, .none: nil
    }
  }

  /// Opens an agent on its own chat: the agent itself, not whatever tab
  /// was last in front.
  func openWorkspace(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    if let home = environment.navigationStore.homeChatId(of: workspace) {
      if let tabId = workspace.tabId(containingChat: home) {
        store?.selectDestination(.tab(tabId), in: workspace.id)
      }
      selection = .session(serverId: workspace.serverId, id: home)
    } else {
      selection = .workspace(serverId: workspace.serverId, id: workspace.id)
    }
  }

  /// Steps the selection through the agents in sidebar order (the menu's
  /// tab-stepping commands when no workspace is in front).
  func stepAgent(_ offset: Int) {
    let rows = agentNodes.flatMap { node -> [AgentSidebarRow] in
      switch node {
      case let .agent(row): [row]
      case let .folder(_, rows), let .project(_, rows): rows
      }
    }.flatMap { AgentSidebarEntry.flattening($0).map(\.row) }
    guard !rows.isEmpty else { return }
    let current = rows.firstIndex { $0.id == selectedWorkspaceId() }
    let next = current.map { ($0 + offset + rows.count) % rows.count } ?? (offset > 0 ? 0 : rows.count - 1)
    openWorkspace(rows[next].id)
  }

  // MARK: - Organizing

  func file(_ workspaceId: UUID, into folder: UUID?) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    environment.navigationStore.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .folder(folder)), machineId: workspace.serverId)
  }

  /// Nests an agent under `owner`, or makes it independent when nil.
  func setOwner(of workspaceId: UUID, to owner: UUID?) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId), workspace.parentWorkspaceId != owner
    else { return }
    environment.navigationStore.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .owner(owner)), machineId: workspace.serverId)
  }

  /// Whether `workspaceId` is `ancestor` or nested somewhere under it.
  func isWithin(_ workspaceId: UUID, _ ancestor: UUID) -> Bool {
    var current: UUID? = workspaceId
    var seen: Set<UUID> = []
    while let id = current, seen.insert(id).inserted {
      if id == ancestor { return true }
      current = environment.workspaces.workspace(id: id)?.parentWorkspaceId
    }
    return false
  }

  private func archive(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    archiveWorkspace(workspace)
  }

  /// A new folder at the top of the sidebar, optionally holding an agent,
  /// named right away.
  private func createFolder(filing workspaceId: UUID?) {
    let id = UUID()
    let first = agentNodes.first.map(nodePosition)
    let position = WorkspacePosition.between(nil, first, id: id) ?? "000000000000" + "8"
    environment.navigationStore.saveFolder(id: id, name: "New Folder", position: position)
    if let workspaceId { file(workspaceId, into: id) }
    if let folder = environment.navigationStore.folders.first(where: { UUID(uuidString: $0.id) == id }) {
      beginFolderRename(folder)
    }
  }

  private func toggleFolder(_ folder: ServerNavigationFolder) {
    guard let id = UUID(uuidString: folder.id) else { return }
    environment.navigationStore.saveFolder(
      id: id, name: folder.name, position: folder.position, collapsed: !folder.collapsed)
  }

  private var folderRenamePresented: Binding<Bool> {
    Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })
  }

  private func beginFolderRename(_ folder: ServerNavigationFolder) {
    folderRenameTitle = folder.name
    renamingFolder = folder
  }

  private func commitFolderRename() {
    guard let folder = renamingFolder, let id = UUID(uuidString: folder.id) else { return }
    let name = folderRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    renamingFolder = nil
    guard !name.isEmpty else { return }
    environment.navigationStore.saveFolder(id: id, name: name, position: folder.position, collapsed: folder.collapsed)
  }

  private func nodePosition(_ node: AgentSidebarNode) -> String {
    switch node {
    case let .agent(row): row.position
    case let .folder(folder, _): folder.position
    case let .project(project, _): project.id.uuidString
    }
  }

  /// Drops agents (or a folder) in front of `target`, joining its folder.
  @discardableResult
  func dropAgents(_ items: [String], before target: AgentSidebarRow) -> Bool {
    let targetFolder = environment.workspaces.workspace(id: target.id)?.folderId
    let siblings = siblingPositions(inFolder: targetFolder)
    guard let index = siblings.firstIndex(where: { $0.id == target.id.uuidString }) else { return false }
    let lower = index > 0 ? siblings[index - 1].position : nil
    var moved = false
    for item in items {
      guard let id = UUID(uuidString: item), id != target.id else { continue }
      guard let position = WorkspacePosition.between(lower, target.position, id: id) else { continue }
      if let workspace = environment.workspaces.workspace(id: id) {
        // Dropped among top-level agents: no longer nested under its owner.
        setOwner(of: id, to: nil)
        environment.navigationStore.enqueue(
          .reorderWorkspace(workspaceId: id, position: position, expectedRevision: workspace.sidebarOrderRevision),
          machineId: workspace.serverId)
        if workspace.folderId != targetFolder { file(id, into: targetFolder) }
        moved = true
      } else if let folder = environment.navigationStore.folders.first(where: { UUID(uuidString: $0.id) == id }),
        targetFolder == nil
      {
        environment.navigationStore.saveFolder(
          id: id, name: folder.name, position: position, collapsed: folder.collapsed)
        moved = true
      }
    }
    return moved
  }

  @discardableResult
  func dropAgents(_ items: [String], intoFolder folder: UUID?) -> Bool {
    let ids = items.compactMap(UUID.init(uuidString:)).filter { environment.workspaces.workspace(id: $0) != nil }
    for id in ids {
      setOwner(of: id, to: nil)
      file(id, into: folder)
    }
    return !ids.isEmpty
  }

  /// Drops agents in front of `target`, nested under its owner: they join
  /// that owner's agents there. An agent can't go under itself.
  @discardableResult
  func dropAgents(_ items: [String], before target: AgentSidebarRow, under owner: AgentSidebarRow) -> Bool {
    let positions = owner.children.map { environment.workspaces.workspace(id: $0.id)?.parentTabPosition }
    guard let index = owner.children.firstIndex(where: { $0.id == target.id }), let upper = positions[index]
    else { return false }
    let lower = index > 0 ? positions[index - 1] : nil
    var moved = false
    for item in items {
      guard let id = UUID(uuidString: item), id != target.id, !isWithin(owner.id, id),
        let workspace = environment.workspaces.workspace(id: id), workspace.serverId == owner.serverId,
        let position = WorkspacePosition.between(lower, upper, id: id)
      else { continue }
      setOwner(of: id, to: owner.id)
      environment.navigationStore.enqueue(
        .updateWorkspaceHierarchy(workspaceId: id, change: .groupPosition(position)), machineId: workspace.serverId)
      moved = true
    }
    return moved
  }

  /// The ids and positions of the entries sharing a level with an agent in
  /// `folder` (the top level when nil), in order.
  func siblingPositions(inFolder folder: UUID?) -> [(id: String, position: String)] {
    let nodes = agentNodes
    if let folder {
      for case let .folder(record, rows) in nodes where UUID(uuidString: record.id) == folder {
        return rows.map { ($0.id.uuidString, $0.position) }
      }
      return []
    }
    return nodes.compactMap { node in
      switch node {
      case let .agent(row): (row.id.uuidString, row.position)
      case let .folder(record, _): (record.id.lowercased(), record.position)
      case .project: nil
      }
    }
  }

  /// Reorders projects: the dropped one goes in front of `target`, and the
  /// whole order is written so every device sorts the same.
  @discardableResult
  private func dropProjects(_ items: [String], before target: Project) -> Bool {
    let projects = agentNodes.compactMap { node -> Project? in
      if case let .project(project, _) = node { return project }
      return nil
    }
    var order = projects.map(\.id)
    var moved = false
    for item in items where item.hasPrefix("project:") {
      guard let id = UUID(uuidString: String(item.dropFirst("project:".count))), id != target.id,
        let from = order.firstIndex(of: id)
      else { continue }
      order.remove(at: from)
      order.insert(id, at: order.firstIndex(of: target.id) ?? order.count)
      moved = true
    }
    guard moved else { return false }
    for (index, id) in order.enumerated() {
      environment.navigationStore.setSetting(
        NavigationStore.projectOrderKeyPrefix + id.uuidString.lowercased(),
        value: String(format: "%08d", (index + 1) * 1024))
    }
    return true
  }
}

/// One sidebar row with its place in the nesting: the agent that owns it,
/// and how deep it sits.
struct AgentSidebarEntry: Identifiable {
  let row: AgentSidebarRow
  let owner: AgentSidebarRow?
  let depth: Int

  var id: UUID { row.id }

  /// An agent, then every agent nested under it, depth first.
  static func flattening(_ row: AgentSidebarRow, owner: AgentSidebarRow? = nil, depth: Int = 0) -> [Self] {
    [Self(row: row, owner: owner, depth: depth)]
      + row.children.flatMap { flattening($0, owner: row, depth: depth + 1) }
  }
}
