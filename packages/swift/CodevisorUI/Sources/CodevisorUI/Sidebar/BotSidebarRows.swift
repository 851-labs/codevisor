import CodevisorCore
import Foundation

public enum BotSidebarRowID: Hashable, Sendable {
  case bot(UUID)
  case section(UUID)
  case archivedSection
}

public struct BotSidebarRow: Identifiable, Equatable {
  public enum Kind: Equatable {
    case bot(BotConversation, section: UUID?)
    case section(CustomSection, isExpanded: Bool)
    case archivedSection(isExpanded: Bool)
    case archivedBot(BotConversation)
  }

  public let kind: Kind

  public init(_ kind: Kind) {
    self.kind = kind
  }

  public var id: BotSidebarRowID {
    switch kind {
    case let .bot(conversation, _), let .archivedBot(conversation): .bot(conversation.id)
    case let .section(section, _): .section(section.id)
    case .archivedSection: .archivedSection
    }
  }

  public var activeBot: Bot? {
    guard case let .bot(conversation, _) = kind else { return nil }
    return conversation.bot
  }

  public var bot: Bot? {
    switch kind {
    case let .bot(conversation, _), let .archivedBot(conversation): conversation.bot
    case .section, .archivedSection: nil
    }
  }
}

public enum BotSidebarRows {
  public struct State: Equatable {
    public var conversations: [BotConversation]
    public var sections: [CustomSection]
    public var membership: [UUID: UUID]
    public var collapsedSectionIDs: Set<UUID>
    public var isArchivedExpanded: Bool
    public var selectedBotID: UUID?

    public init(
      conversations: [BotConversation], sections: [CustomSection] = [], membership: [UUID: UUID] = [:],
      collapsedSectionIDs: Set<UUID> = [], isArchivedExpanded: Bool = false, selectedBotID: UUID? = nil
    ) {
      self.conversations = conversations
      self.sections = sections
      self.membership = membership
      self.collapsedSectionIDs = collapsedSectionIDs
      self.isArchivedExpanded = isArchivedExpanded
      self.selectedBotID = selectedBotID
    }
  }

  public static func derive(_ state: State) -> [BotSidebarRow] {
    let known = Set(state.sections.map(\.id))
    let active = state.conversations.filter { !$0.bot.isArchived }
    let bySection = Dictionary(grouping: active) { conversation in
      state.membership[conversation.id].flatMap { known.contains($0) ? $0 : nil }
    }
    var rows = (bySection[nil] ?? []).map { BotSidebarRow(.bot($0, section: nil)) }
    for section in state.sections {
      let isExpanded = !state.collapsedSectionIDs.contains(section.id)
      rows.append(BotSidebarRow(.section(section, isExpanded: isExpanded)))
      let shown = SidebarCollapse.shown(
        bySection[section.id] ?? [], isExpanded: isExpanded, keeping: state.selectedBotID)
      rows += shown.map { BotSidebarRow(.bot($0, section: section.id)) }
    }
    let archived = state.conversations.filter(\.bot.isArchived)
    guard !archived.isEmpty else { return rows }
    rows.append(BotSidebarRow(.archivedSection(isExpanded: state.isArchivedExpanded)))
    let shown = SidebarCollapse.shown(archived, isExpanded: state.isArchivedExpanded, keeping: state.selectedBotID)
    return rows + shown.map { BotSidebarRow(.archivedBot($0)) }
  }

  public static func replacement(forArchiving botID: UUID, in rows: [BotSidebarRow]) -> Bot? {
    let active = rows.compactMap(\.activeBot)
    guard let index = active.firstIndex(where: { $0.id == botID }) else { return nil }

    if active.indices.contains(index + 1) { return active[index + 1] }
    return active.indices.contains(index - 1) ? active[index - 1] : nil
  }

  public static func step(from selectedID: UUID?, by offset: Int, in rows: [BotSidebarRow]) -> Bot? {
    let bots = rows.compactMap(\.bot)
    guard let current = bots.firstIndex(where: { $0.id == selectedID }) else { return bots.first }

    let target = current + offset
    return bots.indices.contains(target) ? bots[target] : nil
  }
}
