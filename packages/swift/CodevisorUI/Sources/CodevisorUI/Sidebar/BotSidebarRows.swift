import CodevisorCore
import Foundation

public enum BotSidebarRowID: Hashable, Sendable {
  case bot(UUID)
}

public struct BotSidebarRow: Identifiable, Equatable {
  public enum Kind: Equatable {
    case bot(BotConversation)
  }

  public let kind: Kind

  public init(_ kind: Kind) {
    self.kind = kind
  }

  public var id: BotSidebarRowID {
    switch kind {
    case let .bot(conversation): .bot(conversation.id)
    }
  }

  public var bot: Bot? {
    switch kind {
    case let .bot(conversation): conversation.bot
    }
  }
}

public enum BotSidebarRows {
  public struct State: Equatable {
    public var conversations: [BotConversation]

    public init(conversations: [BotConversation]) {
      self.conversations = conversations
    }
  }

  public static func derive(_ state: State) -> [BotSidebarRow] {
    state.conversations.map { BotSidebarRow(.bot($0)) }
  }

  public static func step(from selectedID: UUID?, by offset: Int, in rows: [BotSidebarRow]) -> Bot? {
    let bots = rows.compactMap(\.bot)
    guard let current = bots.firstIndex(where: { $0.id == selectedID }) else { return bots.first }

    let target = current + offset
    return bots.indices.contains(target) ? bots[target] : nil
  }
}
