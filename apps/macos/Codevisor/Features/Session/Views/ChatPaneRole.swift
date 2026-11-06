import CodevisorCore
import Foundation

enum ChatPaneRole: Equatable {
  case chat
  case botConversation
  case botBubbles
  case fullTranscript
  case childAgent

  var botMode: BotMode? {
    switch self {
    case .botConversation: .conversation
    case .botBubbles: .bubbles
    case .chat, .fullTranscript, .childAgent: nil
    }
  }
  var isReadOnly: Bool { self == .fullTranscript }
  var offersNewChat: Bool { self == .chat }

  func sessionId(of descriptor: PaneDescriptorState) -> UUID? {
    switch self {
    case .chat, .botConversation, .botBubbles, .childAgent: descriptor.chatSessionId
    case .fullTranscript: descriptor.ownerChatSessionId
    }
  }
}
