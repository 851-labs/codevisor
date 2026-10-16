import CodevisorCore

enum BotEditorTarget: Identifiable {
  case create
  case edit(Bot)

  var id: String {
    switch self {
    case .create: "create"
    case let .edit(bot): bot.id.uuidString
    }
  }
}
