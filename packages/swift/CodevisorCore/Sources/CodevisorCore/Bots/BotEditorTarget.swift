import Foundation

public enum BotEditorTarget: Identifiable, Hashable {
  case create
  case edit(Bot)
  case fork(Bot)

  public var id: String {
    switch self {
    case .create: "create"
    case let .edit(bot): bot.id.uuidString
    case let .fork(bot): "fork-\(bot.id.uuidString)"
    }
  }
}
