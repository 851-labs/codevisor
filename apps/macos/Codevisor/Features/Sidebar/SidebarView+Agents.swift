import CodevisorCore
import CodevisorUI
import SwiftUI

/// The agent-first sidebar: one row per agent the user manages, with that
/// agent's subagents one level in (collapsed by default), grouped the way
/// the user chose -- folders and loose agents, or projects. Grouping,
/// folders and order are shared by every device; which agents are expanded
/// is this device's own.
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
        Toggle(
          "Show Subagents",
          isOn: Binding(
            get: { navigation.showsSubagents },
            set: { navigation.setSetting(NavigationStore.sidebarSubagentsKey, value: $0 ? "nested" : "hidden") }))
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
      agentBlock(row)
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
        .dropDestination(for: String.self) { items, _ in
          dropAgents(items, intoFolder: UUID(uuidString: folder.id))
        }
        if !folder.collapsed {
          ForEach(rows) { row in
            agentBlock(row).padding(.leading, 10)
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
          ForEach(rows) { row in agentBlock(row) }
        }
      }
    }
  }

  private func agentBlock(_ row: AgentSidebarRow) -> some View {
    let navigation = environment.navigationStore
    let isExpanded = expandedAgents.contains(row.id)
    return VStack(alignment: .leading, spacing: 1) {
      AgentRowView(
        row: row, detail: agentDetail(row), isSelected: isAgentSelected(row),
        isExpanded: isExpanded, showsSubagents: navigation.showsSubagents,
        onActivate: { openWorkspace(row.id) },
        onToggle: {
          if isExpanded {
            expandedAgents.remove(row.id)
          } else {
            expandedAgents.insert(row.id)
          }
        }
      )
      .draggable(row.id.uuidString)
      .dropDestination(for: String.self) { items, _ in
        dropAgents(items, before: row)
      }
      .contextMenu { agentMenu(row) }
      if isExpanded, navigation.showsSubagents {
        ForEach(row.subagents) { subagent in
          SubagentRowView(
            subagent: subagent, isSelected: isSubagentSelected(subagent),
            onActivate: { openSubagent(subagent) }
          )
          .contextMenu {
            if subagent.kind == .workspace {
              Button("Move to Sidebar") { promote(subagent.workspaceId) }
              Button("Archive") { archive(subagent.workspaceId) }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func agentMenu(_ row: AgentSidebarRow) -> some View {
    let navigation = environment.navigationStore
    Button("Rename…") {
      guard let workspace = environment.workspaces.workspace(id: row.id) else { return }
      workspaceRenameTitle = workspace.name
      renamingWorkspace = workspace
    }
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

  /// The branch it runs on, and the machine when it isn't this one.
  private func agentDetail(_ row: AgentSidebarRow) -> String? {
    let machine = environment.machines.machine(for: row.serverId).flatMap { $0.isLocal ? nil : $0.name }
    let parts = [row.branch, machine].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Selection

  private func selectedWorkspaceId() -> UUID? {
    switch selection {
    case let .session(_, sessionId): environment.workspaces.workspaceId(forSession: sessionId)
    case let .workspace(_, id): id
    case .newChat, .none: nil
    }
  }

  private func isAgentSelected(_ row: AgentSidebarRow) -> Bool {
    guard let selected = selectedWorkspaceId() else { return false }
    if selected != row.id { return false }
    if case let .session(_, sessionId) = selection {
      return !row.subagents.contains { $0.kind == .chat && $0.id == sessionId }
    }
    return true
  }

  private func isSubagentSelected(_ subagent: AgentSidebarSubagent) -> Bool {
    switch subagent.kind {
    case .chat:
      if case let .session(_, sessionId) = selection { return sessionId == subagent.id }
      return false
    case .workspace:
      return selectedWorkspaceId() == subagent.workspaceId
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

  private func openSubagent(_ subagent: AgentSidebarSubagent) {
    switch subagent.kind {
    case .workspace:
      openWorkspace(subagent.workspaceId)
    case .chat:
      guard let workspace = environment.workspaces.workspace(id: subagent.workspaceId) else { return }
      if let tabId = workspace.tabId(containingChat: subagent.id) {
        store?.selectDestination(.tab(tabId), in: workspace.id)
      }
      selection = .session(serverId: workspace.serverId, id: subagent.id)
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
    }
    guard !rows.isEmpty else { return }
    let current = rows.firstIndex { $0.id == selectedWorkspaceId() }
    let next = current.map { ($0 + offset + rows.count) % rows.count } ?? (offset > 0 ? 0 : rows.count - 1)
    openWorkspace(rows[next].id)
  }

  // MARK: - Organizing

  private func file(_ workspaceId: UUID, into folder: UUID?) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    environment.navigationStore.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .folder(folder)), machineId: workspace.serverId)
  }

  private func promote(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    environment.navigationStore.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .owner(nil)), machineId: workspace.serverId)
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
  private func dropAgents(_ items: [String], before target: AgentSidebarRow) -> Bool {
    let targetFolder = environment.workspaces.workspace(id: target.id)?.folderId
    let siblings = siblingPositions(inFolder: targetFolder)
    guard let index = siblings.firstIndex(where: { $0.id == target.id.uuidString }) else { return false }
    let lower = index > 0 ? siblings[index - 1].position : nil
    var moved = false
    for item in items {
      guard let id = UUID(uuidString: item), id != target.id else { continue }
      guard let position = WorkspacePosition.between(lower, target.position, id: id) else { continue }
      if let workspace = environment.workspaces.workspace(id: id) {
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
  private func dropAgents(_ items: [String], intoFolder folder: UUID?) -> Bool {
    let ids = items.compactMap(UUID.init(uuidString:)).filter { environment.workspaces.workspace(id: $0) != nil }
    for id in ids { file(id, into: folder) }
    return !ids.isEmpty
  }

  /// The ids and positions of the entries sharing a level with an agent in
  /// `folder` (the top level when nil), in order.
  private func siblingPositions(inFolder folder: UUID?) -> [(id: String, position: String)] {
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
