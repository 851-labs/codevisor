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
  var mode: Binding<SidebarMode>? = nil
  var refreshDetails: ([UUID], [SidebarRowDetail]) -> Void = { _, _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var grouping
  @ClientPreference(SidebarGrouping.collapsedPreferenceKey, default: []) private var collapsedGroupIDs: [String]
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedIDs: [String]
  @ClientPreference(SidebarPreferenceKey.machineOrder, default: []) private var machineOrder: [String]
  @ClientPreference(SidebarPreferenceKey.projectOrder, default: []) private var projectOrder: [String]
  @ClientPreference(SidebarPreferenceKey.pinnedExpanded, default: true) private var pinnedExpanded
  @ClientPreference(SidebarPreferenceKey.listExpanded, default: true) private var listExpanded
  @ClientPreference(SidebarPreferenceKey.archivedExpanded, default: false) private var archivedExpanded
  @ClientPreference(SidebarPreferenceKey.botsExpanded, default: true) private var botsExpanded
  @ClientPreference(Self.expandedWorkspacesKey, default: []) private var expandedWorkspaceIDs: [String]
  @State private var archivedLimit = sidebarArchivedPageSize
  @State private var pendingSelection: UUID?

  private var rowDetails: [SidebarRowDetail] { ClientPreferences.shared.sidebarRowDetails }

  private var preferences: HomeSidebarPreferences {
    HomeSidebarPreferences(
      grouping: grouping, pinnedIDs: pinnedIDs, machineOrder: machineOrder, projectOrder: projectOrder,
      rowDetails: rowDetails,
      archivedLimit: archivedLimit)
  }

  var body: some View {
    let content = makeContent(preferences)
    list(content)
      .modifier(HomeSidebarListStyle(isConversation: isConversation))
      .overlay {
        if showsBotsEmptyOverlay(content) { botsEmptyState }
      }
      .animation(Motion.listReflow(reduceMotion: reduceMotion), value: content.layout)
      .onAppear { followSelection(from: nil, to: selected, in: content) }
      .onChange(of: selected) { previous, next in
        pendingSelection = nil
        followSelection(from: previous, to: next, in: content)
      }
      .refreshable {
        await actions.actions.refresh()
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

  private func gitRefreshKey(_ content: HomeSidebarContent) -> SidebarGitLookups.RefreshKey? {
    let shown = detailedWorkspaceIDs(content)
    let archived = Set(content.archived.map(\.id))
    return SidebarGitLookups.refreshKey(
      details: rowDetails, workspaceIds: shown.filter { !archived.contains($0) },
      archivedWorkspaceIds: shown.filter(archived.contains))
  }

  private var showsChat: Bool { mode?.wrappedValue != .code }

  private var isConversation: Bool { mode?.wrappedValue == .bots }

  private var showsCode: Bool { mode?.wrappedValue != .bots }

  private func followSelection(
    from previous: HomeSidebarSelection?, to next: HomeSidebarSelection?, in content: HomeSidebarContent
  ) {
    let owner = next.flatMap(content.mode(owning:))
    guard let mode, let owner, owner != previous.flatMap(content.mode(owning:)), owner != mode.wrappedValue
    else { return }

    mode.wrappedValue = owner
  }

  private func detailedWorkspaceIDs(_ content: HomeSidebarContent) -> [UUID] {
    var shown = showsCode ? codeWorkspaces(content).flatMap(\.subtree) : []
    if archivedExpanded { shown += archivedWorkspaces(content) }
    return shown.map(\.id)
  }

  private func shownBots(_ content: HomeSidebarContent) -> [HomeSidebarBot] {
    switch mode?.wrappedValue {
    case .bots:
      let expanded = content.botSectionGroups.filter { !collapsedGroupIDs.contains($0.collapseID) }
      return content.unsectionedBots + expanded.flatMap(\.bots)
    case .code: return []
    case nil: return botsExpanded ? content.bots : []
    }
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

  @ViewBuilder
  private func list(_ content: HomeSidebarContent) -> some View {
    if isSelectable {
      List(selection: selection(content)) {
        sections(content)
      }
    } else {
      List {
        sections(content)
      }
    }
  }

  @ViewBuilder
  private func sections(_ content: HomeSidebarContent) -> some View {
    switch mode?.wrappedValue {
    case .bots:
      chatSections(content)
      archivedSection(content)
    case .code:
      codeSections(content)
      archivedSection(content)
    case nil:
      if content.showsBots { botsSection(content) }
      codeSections(content)
      archivedSection(content)
    }
  }

  @ViewBuilder
  private func codeSections(_ content: HomeSidebarContent) -> some View {
    outlineRows(
      .code(content, expansion: outlineExpansion), sections: content.customSections,
      sectionActions: actions.actions.workspaceSections)
    if listExpanded && content.listedWorkspaces.isEmpty {
      Text("No Workspaces")
        .foregroundStyle(.tertiary)
    }
  }

  private func chatSections(_ content: HomeSidebarContent) -> some View {
    outlineRows(
      .bots(content, expansion: outlineExpansion), sections: content.botSections,
      sectionActions: actions.actions.botSections)
  }

  private func outlineRows(
    _ outline: HomeSidebarOutline, sections: [CustomSection], sectionActions: HomeSidebarSectionActions
  ) -> some View {
    HomeSidebarOutlineRows(
      outline: outline, sections: sections, sectionActions: sectionActions, actions: actions,
      isSelectable: isSelectable, isConversation: isConversation, selectedID: isSelectable ? selected?.rowID : nil,
      expansion: expansion
    ) { bot in
      botRow(bot, sections: sections)
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

  private func botsSection(_ content: HomeSidebarContent) -> some View {
    Section("Bots", isExpanded: animated($botsExpanded)) {
      ForEach(content.bots) { bot in
        botRow(bot)
      }
      if content.canCreateBots { newBotButton }
    }
  }

  private var newBotButton: some View {
    Button(action: actions.actions.newBot) {
      Label("New Bot…", symbol: .mascotBadgePlus)
    }
    .accessibilityIdentifier("sidebar.newBot")
  }

  @ViewBuilder
  private func archivedSection(_ content: HomeSidebarContent) -> some View {
    let bots = showsChat ? content.archivedBots : []
    let showsWorkspaces = showsCode && content.archivedCount > 0
    if showsWorkspaces || !bots.isEmpty {
      HomeSidebarCollapsibleSection(
        title: "Archived", isExpanded: animated($archivedExpanded), isConversation: isConversation
      ) {
        archivedRows(content, bots: bots, showsWorkspaces: showsWorkspaces)
      }
    }
  }

  @ViewBuilder
  private func archivedRows(
    _ content: HomeSidebarContent, bots: [HomeSidebarBot], showsWorkspaces: Bool
  ) -> some View {
    ForEach(bots) { bot in
      botRow(bot)
    }
    if showsWorkspaces {
      ForEach(content.archived) { workspace in
        HomeSidebarWorkspaceRowView(workspace: workspace, actions: actions, isSelectionRow: isSelectable)
          .equatable()
      }
      if content.archivedCount > content.archived.count {
        Button("Show More") {
          withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
            archivedLimit += sidebarArchivedPageSize
          }
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func botRow(_ bot: HomeSidebarBot, sections: [CustomSection]? = nil) -> some View {
    let row = HomeSidebarBotRowView(
      bot: bot, actions: actions, isSelectionRow: isSelectable, isOpen: selected == .bot(bot.id), sections: sections,
      isConversation: isConversation
    )
    .equatable()
    .tag(bot.id)
    if !bot.hasNestedRows {
      row
    } else {
      DisclosureGroup(isExpanded: tabExpansion(bot.id)) {
        if let home = bot.home {
          ForEach(bot.tabs) { tab in
            HomeSidebarTabRowView(row: tab, workspace: home.workspace, actions: actions, isSelectionRow: isSelectable)
              .equatable()
              .tag(tab.id)
          }
        }
      } label: {
        row
      }
    }
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

  private func selection(_ content: HomeSidebarContent) -> Binding<UUID?> {
    Binding(
      get: { pendingSelection ?? selectedRowID(content) },
      set: { id in
        guard let id else { return }
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
    )
  }
}
