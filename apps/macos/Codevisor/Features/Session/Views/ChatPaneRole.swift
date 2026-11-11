import CodevisorCore
import Foundation

enum ChatPaneRole: Equatable {
  case chat
  case botConversation
  case fullTranscript
  case childAgent

  var isReadOnly: Bool { self == .fullTranscript }
  var offersNewChat: Bool { self == .chat }

  func sessionId(of descriptor: PaneDescriptorState) -> UUID? {
    switch self {
    case .chat, .botConversation, .childAgent: descriptor.chatSessionId
    case .fullTranscript: descriptor.ownerChatSessionId
    }
  }
}
