import Foundation

struct CachedChatKey: Hashable, Sendable {
  let machineId: String
  let chatId: String

  init(machineId: String, chatId: UUID) {
    self.machineId = machineId
    self.chatId = chatId.uuidString.lowercased()
  }

  var bindings: [ClientDatabase.Binding] { [.text(machineId), .text(chatId)] }
}
