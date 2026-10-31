import CodevisorCore
import Foundation

public enum BotSidebarRowID: Hashable, Sendable {
  case bot(UUID)
  case section(UUID)
}

public struct BotSidebarRow: Identifiable, Equatable {
  public enum Kind: Equatable {
    case bot(BotConversation, section: UUID?)
    case section(CustomSection, isExpanded: Bool)
  }

  public let kind: Kind

  public init(_ kind: Kind) {
    self.kind = kind
  }

  public var id: BotSidebarRowID {
    switch kind {
    case let .bot(conversation, _): .bot(conversation.id)
    case let .section(section, _): .section(section.id)
    }
  }

  public var bot: Bot? {
    switch kind {
    case let .bot(conversation, _): conversation.bot
    case .section: nil
    }
  }
}

public enum BotSidebarRows {
  public struct State: Equatable {
    public var conversations: [BotConversation]
    public var sections: [CustomSection]
    public var membership: [UUID: UUID]
    public var collapsedSectionIDs: Set<UUID>
    public var selectedBotID: UUID?

    public init(
      conversations: [BotConversation], sections: [CustomSection] = [], membership: [UUID: UUID] = [:],
      collapsedSectionIDs: Set<UUID> = [], selectedBotID: UUID? = nil
    ) {
      self.conversations = conversations
      self.sections = sections
      self.membership = membership
      self.collapsedSectionIDs = collapsedSectionIDs
      self.selectedBotID = selectedBotID
    }
  }

  public static func derive(_ state: State) -> [BotSidebarRow] {
    let known = Set(state.sections.map(\.id))
    let bySection = Dictionary(grouping: state.conversations) { conversation in
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
    return rows
  }

  public static func step(from selectedID: UUID?, by offset: Int, in rows: [BotSidebarRow]) -> Bot? {
    let bots = rows.compactMap(\.bot)
    guard let current = bots.firstIndex(where: { $0.id == selectedID }) else { return bots.first }

    let target = current + offset
    return bots.indices.contains(target) ? bots[target] : nil
  }
}
