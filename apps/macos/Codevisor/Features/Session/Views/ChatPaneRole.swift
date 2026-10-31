import CodevisorCore
import Foundation

enum ChatPaneRole: Equatable {
  case chat
  case botConversation
  case botBubbles
  case fullTranscript

  var botMode: BotMode? {
    switch self {
    case .botConversation: .conversation
    case .botBubbles: .bubbles
    case .chat, .fullTranscript: nil
    }
  }
  var isReadOnly: Bool { self == .fullTranscript }
  var offersNewChat: Bool { self == .chat }

  func sessionId(of descriptor: PaneDescriptorState) -> UUID? {
    switch self {
    case .chat, .botConversation, .botBubbles: descriptor.chatSessionId
    case .fullTranscript: descriptor.ownerChatSessionId
    }
  }
}
