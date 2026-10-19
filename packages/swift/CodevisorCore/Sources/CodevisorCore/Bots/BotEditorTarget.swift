import Foundation

public enum BotEditorTarget: Identifiable, Hashable {
  case create
  case edit(Bot)

  public var id: String {
    switch self {
    case .create: "create"
    case let .edit(bot): bot.id.uuidString
    }
  }
}
