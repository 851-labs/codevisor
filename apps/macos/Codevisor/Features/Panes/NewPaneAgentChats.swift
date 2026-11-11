import Foundation

struct NewPaneAgentChats {
  struct Chat: Identifiable, Equatable {
    let id: UUID
    let name: String
  }

  let chats: [Chat]
  let open: (Chat) -> Void
}
