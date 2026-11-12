import CodevisorCore
import CodevisorUI
import Foundation

struct SidebarRestorePlan {
  let environment: AppEnvironment

  func restore(_ remembered: RememberedSidebarSelection?, in mode: SidebarMode) -> SidebarRestore<SidebarSelection> {
    switch mode {
    case .bots:
      SidebarRestore.first(of: chatCandidates(remembered), orElse: nil, availability: availability)
    case .code:
      SidebarRestore.first(of: codeCandidates(remembered), orElse: .newChat(nil), availability: availability)
    }
  }

  func remembering(_ selection: SidebarSelection) -> RememberedSidebarSelection {
    RememberedSidebarSelection(selection: selection, workspaceId: workspaceId(of: selection))
  }

  func reopening(_ remembered: RememberedSidebarSelection) -> SidebarSelection? {
    let restore = SidebarRestore.first(of: codeCandidates(remembered), orElse: nil, availability: availability)
    guard case let .select(target) = restore else { return nil }

    return target
  }

  private func chatCandidates(_ remembered: RememberedSidebarSelection?) -> [SidebarSelection] {
    [remembered?.selection].compactMap { $0 } + recentBots
  }

  private func codeCandidates(_ remembered: RememberedSidebarSelection?) -> [SidebarSelection] {
    [remembered?.selection, remembered?.parentWorkspace].compactMap { $0 }
  }

  private var recentBots: [SidebarSelection] {
    BotConversationList(environment: environment, store: nil).conversations()
      .map(\.bot)
      .filter { !$0.isArchived }
      .map { .bot(serverId: $0.serverId, id: $0.id) }
  }

  private func workspaceId(of selection: SidebarSelection) -> UUID? {
    switch selection {
    case let .session(_, id): environment.workspaces.workspaceId(forSession: id)
    case let .workspace(_, id), let .archivedWorkspace(_, id): id
    case .bot, .newChat: nil
    }
  }

  private func availability(of selection: SidebarSelection) -> SidebarItemAvailability {
    switch selection {
    case let .bot(serverId, id):
      SidebarItemAvailability(botListing(serverId: serverId, id: id), on: botMachine(serverId))
    case let .session(serverId, id):
      SidebarItemAvailability(chatListing(serverId: serverId, id: id), on: machine(serverId))
    case let .workspace(serverId, id): SidebarItemAvailability(workspaceListing(id), on: machine(serverId))
    case let .archivedWorkspace(serverId, id): SidebarItemAvailability(archivedListing(id), on: machine(serverId))
    case .newChat: .available
    }
  }

  private func botListing(serverId: String, id: UUID) -> SidebarItemAvailability.Listing {
    guard let bot = environment.bots.bot(serverId: serverId, id: id) else { return .missing }

    return bot.isArchived ? .hidden : .listed
  }

  private func chatListing(serverId: String, id: UUID) -> SidebarItemAvailability.Listing {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: id) else {
      return environment.projectList.session(id, serverId: serverId) == nil ? .missing : .listed
    }

    let workspace = workspaceListing(workspaceId)
    guard workspace == .listed else { return workspace }

    return environment.workspaces.workspace(id: workspaceId)?.tabId(containingChat: id) == nil ? .hidden : .listed
  }

  private func workspaceListing(_ id: UUID) -> SidebarItemAvailability.Listing {
    let entries = environment.navigationStore.workspaceEntries
    if entries.sidebar.contains(where: { $0.id == id }) { return .listed }
    if entries.archived.contains(where: { $0.id == id }) { return .hidden }
    return .missing
  }

  private func archivedListing(_ id: UUID) -> SidebarItemAvailability.Listing {
    switch workspaceListing(id) {
    case .listed: .hidden
    case .hidden: .listed
    case .missing: .missing
    }
  }

  private func machine(_ serverId: String) -> SidebarItemAvailability.Machine {
    guard environment.machines.machine(for: serverId) != nil else { return isRosterLoading ? .connecting : .unknown }

    switch environment.machines.navigationSyncStateByMachineId[serverId] {
    case .current: return .reachable
    case .stale: return .unreachable
    case .cached, .catchingUp, nil: return .connecting
    }
  }

  private func botMachine(_ serverId: String) -> SidebarItemAvailability.Machine {
    let machine = machine(serverId)
    guard machine == .reachable, !hasLoadedBots(on: serverId) else { return machine }

    return .connecting
  }

  private func hasLoadedBots(on serverId: String) -> Bool {
    let lacksBots = environment.machines.statusByMachineId[serverId].map { !$0.supportsBots } ?? false
    return environment.bots.recordsByServer[serverId] != nil || lacksBots
  }

  private var isRosterLoading: Bool { environment.navigationRosterStatus == .unverified }
}
