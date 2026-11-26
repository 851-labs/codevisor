import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarActions {
  var open: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var openWorkspace: (HomeSidebarWorkspace) -> Void = { _ in }
  var close: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var newTab: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var newChat: (NewChatTarget) -> Void = { _ in }
  var togglePin: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var renameWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var archiveWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var restoreWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var workspaceSections = HomeSidebarSectionActions()
  var botSections = HomeSidebarSectionActions()
  var reorder: (UUID, Int, [UUID]) -> Void = { _, _, _ in }
  var placeBot: (Bot, SidebarPlacement) -> Void = { _, _ in }
  var placeWorkspace: (_ id: UUID, SidebarPlacement, _ siblings: [UUID], _ movesSection: Bool) -> Void = { _, _, _, _ in
  }
  var moveTab: (UUID, UUID?, HomeSidebarWorkspaceRef) -> Void = { _, _, _ in }
  var openInNewWindow: ((HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void)?
  var openWorkspaceInNewWindow: ((HomeSidebarWorkspace) -> Void)?
  var openBot: (Bot) -> Void = { _ in }
  var newBot: () -> Void = {}
  var editBot: (Bot) -> Void = { _ in }
  var forkBot: (Bot) -> Void = { _ in }
  var archiveBot: (Bot) -> Void = { _ in }
  var unarchiveBot: (Bot) -> Void = { _ in }
  var deleteBot: (Bot) -> Void = { _ in }
  var setUnread: (_ chatSessionId: UUID, _ serverId: String, _ isUnread: Bool) -> Void = { _, _, _ in }
  var didSelectInSplit: () -> Void = {}
  var refresh: () async -> Void = {}
}

@MainActor
final class HomeSidebarActionHandler {
  var actions: HomeSidebarActions

  init(_ actions: HomeSidebarActions) {
    self.actions = actions
  }
}

enum HomeSidebarSelection: Equatable {
  case workspace(UUID, paneId: UUID?)
  case bot(UUID)

  var rowID: UUID {
    switch self {
    case let .workspace(id, paneId): paneId ?? id
    case let .bot(id): id
    }
  }
}

struct HomeSidebarList: View {
  static let expandedWorkspacesKey = "ios.sidebar.expandedWorkspaces"

  let makeContent: (HomeSidebarPreferences) -> HomeSidebarContent
  let actions: HomeSidebarActionHandler
  var isSelectable = false
  var selected: HomeSidebarSelection? = nil
  let mode: Binding<SidebarMode>
  var refreshDetails: ([UUID], [SidebarRowDetail]) -> Void = { _, _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) private var collapsedGroupIDs: [String]
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedIDs: [String]
  @ClientPreference(SidebarPreferenceKey.machineOrder, default: []) private var machineOrder: [String]
  @ClientPreference(SidebarPreferenceKey.projectOrder, default: []) private var projectOrder: [String]
  @ClientPreference(SidebarPreferenceKey.pinnedExpanded, default: true) private var pinnedExpanded
  @ClientPreference(SidebarPreferenceKey.listExpanded, default: true) private var listExpanded
  @ClientPreference(SidebarPreferenceKey.archivedExpanded, default: false) private var archivedExpanded
  @ClientPreference(Self.expandedWorkspacesKey, default: []) private var expandedWorkspaceIDs: [String]
  @State private var archivedLimit = sidebarArchivedPageSize
  @State private var pendingSelection: UUID?

  private var rowDetails: [SidebarRowDetail] { ClientPreferences.shared.sidebarRowDetails }
  private var grouping: SidebarGrouping { SidebarGroupingChoice(machines: environment.machines).effective }

  private var preferences: HomeSidebarPreferences {
    HomeSidebarPreferences(
      grouping: grouping, pinnedIDs: pinnedIDs, machineOrder: machineOrder, projectOrder: projectOrder,
      rowDetails: rowDetails,
      archivedLimit: archivedLimit)
  }

  var body: some View {
    let content = makeContent(preferences)
    collection(content)
      .ignoresSafeArea(.container, edges: .vertical)
      .overlay {
        if showsBotsEmptyOverlay(content) { botsEmptyState }
      }
      .onAppear { followSelection(from: nil, to: selected, in: content) }
      .onChange(of: selected) { previous, next in
        pendingSelection = nil
        followSelection(from: previous, to: next, in: content)
      }
      .task(id: gitRefreshKey(content)) {
        let ids = detailedWorkspaceIDs(content)
        guard gitRefreshKey(content) != nil else { return }
        while !Task.isCancelled {
          refreshDetails(ids, rowDetails)
          try? await Task.sleep(for: .seconds(60))
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshDetails(detailedWorkspaceIDs(content), rowDetails) }
      }
  }

  private func collection(_ content: HomeSidebarContent) -> HomeSidebarCollection {
    let outline = outlineRows(content)
    return HomeSidebarCollection(
      rows: outline.rows + noticeRows(content) + archivedRows(content).rows,
      appearance: isConversation ? .plain : .sidebar,
      selectedID: isSelectable ? pendingSelection ?? selectedRowID(content) : nil,
      isSelectable: isSelectable,
      animates: !reduceMotion,
      onMove: outline.move,
      onSelect: { open($0, in: content) },
      onRefresh: actions.actions.refresh)
  }

  private func gitRefreshKey(_ content: HomeSidebarContent) -> SidebarGitLookups.RefreshKey? {
    let shown = detailedWorkspaceIDs(content)
    let archived = Set(content.archived.map(\.id))
    return SidebarGitLookups.refreshKey(
      details: rowDetails, workspaceIds: shown.filter { !archived.contains($0) },
      archivedWorkspaceIds: shown.filter(archived.contains))
  }

  private var isConversation: Bool { mode.wrappedValue == .bots }

  private var showsCode: Bool { !isConversation }

  private func followSelection(
    from previous: HomeSidebarSelection?, to next: HomeSidebarSelection?, in content: HomeSidebarContent
  ) {
    let owner = next.flatMap(content.mode(owning:))
    guard let owner, owner != previous.flatMap(content.mode(owning:)), owner != mode.wrappedValue else { return }

    mode.wrappedValue = owner
  }

  private func detailedWorkspaceIDs(_ content: HomeSidebarContent) -> [UUID] {
    var shown = showsCode ? codeWorkspaces(content).flatMap(\.subtree) : []
    if archivedExpanded { shown += archivedWorkspaces(content) }
    return shown.map(\.id)
  }

  private func codeWorkspaces(_ content: HomeSidebarContent) -> [HomeSidebarWorkspace] {
    var shown = pinnedExpanded ? content.pinned : []
    for group in content.sections where !collapsedGroupIDs.contains(group.collapseID) {
      shown += group.workspaces
    }
    if listExpanded {
      for group in content.groups where group.heading == nil || !collapsedGroupIDs.contains(group.id) {
        shown += group.workspaces
      }
    }
    return shown
  }

  private func archivedWorkspaces(_ content: HomeSidebarContent) -> [HomeSidebarWorkspace] {
    showsCode ? content.archived : []
  }

  private func outlineRows(_ content: HomeSidebarContent) -> HomeSidebarOutlineRows {
    let outline: HomeSidebarOutline =
      isConversation
      ? .bots(content, expansion: outlineExpansion) : .code(content, expansion: outlineExpansion)
    let sections = isConversation ? content.botSections : content.customSections
    return HomeSidebarOutlineRows(
      outline: outline, sections: sections,
      sectionActions: isConversation ? actions.actions.botSections : actions.actions.workspaceSections,
      actions: actions, isSelectable: true, isConversation: isConversation,
      selectedID: isSelectable ? selected?.rowID : nil, expansion: expansion
    ) { bot, template in
      botRows.rows(bot, template: template, sections: sections)
    }
  }

  private func noticeRows(_ content: HomeSidebarContent) -> [HomeSidebarCollectionRow] {
    guard showsCode, listExpanded, content.listedWorkspaces.isEmpty else { return [] }

    let notice = Text("No Workspaces").foregroundStyle(.tertiary)
    return [HomeSidebarCollectionRow(id: .notice, content: AnyView(notice))]
  }

  private func archivedRows(_ content: HomeSidebarContent) -> HomeSidebarArchivedRows {
    HomeSidebarArchivedRows(
      bots: isConversation ? content.archivedBots : [],
      workspaces: showsCode ? content.archived : [],
      hasMoreWorkspaces: showsCode && content.archivedCount > content.archived.count,
      isExpanded: animated($archivedExpanded), isConversation: isConversation, actions: actions, isSelectable: true,
      botRows: { bot, template in botRows.rows(bot, template: template, sections: nil) },
      showMore: showMoreArchived)
  }

  private var botRows: HomeSidebarBotRows {
    HomeSidebarBotRows(
      actions: actions, isSelectable: true, selected: selected, isConversation: isConversation,
      tabExpansion: tabExpansion)
  }

  private func showMoreArchived() {
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
      archivedLimit += sidebarArchivedPageSize
    }
  }

  private var outlineExpansion: HomeSidebarOutline.Expansion {
    HomeSidebarOutline.Expansion(pinned: pinnedExpanded, list: listExpanded, collapsedIDs: Set(collapsedGroupIDs))
  }

  private func expansion(_ header: HomeSidebarOutline.Header) -> Binding<Bool> {
    switch header {
    case .pinned: animated($pinnedExpanded)
    case .list: animated($listExpanded)
    case .section, .group: groupExpansion(header.id)
    }
  }

  private func showsBotsEmptyOverlay(_ content: HomeSidebarContent) -> Bool {
    isConversation && !content.hasBots
  }

  private var botsEmptyState: some View {
    BotsEmptyState(onNewBot: actions.actions.newBot)
  }

  private func animated(_ binding: Binding<Bool>) -> Binding<Bool> {
    binding.animation(Motion.listReflow(reduceMotion: reduceMotion))
  }

  private func groupExpansion(_ id: String) -> Binding<Bool> {
    animated(
      Binding(
        get: { !collapsedGroupIDs.contains(id) },
        set: { isExpanded in
          collapsedGroupIDs.removeAll { $0 == id }
          if !isExpanded { collapsedGroupIDs.append(id) }
        }
      ))
  }

  private func tabExpansion(_ id: UUID) -> Binding<Bool> {
    let key = id.uuidString
    return animated(
      Binding(
        get: { expandedWorkspaceIDs.contains(key) },
        set: { isExpanded in
          expandedWorkspaceIDs.removeAll { $0 == key }
          if isExpanded { expandedWorkspaceIDs.append(key) }
        }
      ))
  }

  private func selectedRowID(_ content: HomeSidebarContent) -> UUID? {
    switch selected {
    case nil:
      return nil
    case let .bot(botId):
      return botId
    case let .workspace(workspaceId, paneId):
      if let paneId, let workspace = content.workspace(workspaceId),
        workspace.nestedRows.contains(where: { $0.id == paneId })
      {
        return paneId
      }
      return workspaceId
    }
  }

  private func open(_ id: UUID, in content: HomeSidebarContent) {
    guard !isSelectable else { return select(id, in: content) }

    if let bot = content.bot(id) ?? content.archivedBots.first(where: { $0.id == id }) {
      actions.actions.openBot(bot.bot)
    } else if let (row, workspace) = content.row(id) {
      actions.actions.open(row, workspace.workspace)
    } else if let workspace = content.workspace(id) {
      actions.actions.openWorkspace(workspace)
    }
  }

  private func select(_ id: UUID, in content: HomeSidebarContent) {
    if let bot = content.bot(id) {
      pendingSelection = id
      actions.actions.openBot(bot.bot)
    } else if let (row, workspace) = content.row(id) {
      pendingSelection = id
      actions.actions.open(row, workspace.workspace)
    } else if let workspace = content.workspace(id) {
      pendingSelection = id
      actions.actions.openWorkspace(workspace)
    } else {
      return
    }
    actions.actions.didSelectInSplit()
  }
}
