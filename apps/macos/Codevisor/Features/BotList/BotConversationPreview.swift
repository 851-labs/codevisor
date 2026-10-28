import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationPreview: View {
  private static let lineCount = 2

  let conversation: BotConversation

  var body: some View {
    Group {
      if conversation.activity == .working {
        ZStack(alignment: .topLeading) {
          Text(verbatim: " ")
            .lineLimit(Self.lineCount, reservesSpace: true)
            .hidden()
          BotTypingBubble()
        }
      } else {
        Text(text)
          .lineLimit(Self.lineCount, reservesSpace: true)
          .foregroundStyle(foreground)
      }
    }
    .font(.body)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var text: String {
    switch conversation.activity {
    case .waitingOnUser: "Needs your input"
    case .failed: "Something went wrong"
    case .idle, .working: conversation.preview ?? "No messages yet"
    }
  }

  private var foreground: AnyShapeStyle {
    switch conversation.activity {
    case .waitingOnUser: AnyShapeStyle(.orange)
    case .failed: AnyShapeStyle(.red)
    case .idle, .working: AnyShapeStyle(.secondary)
    }
  }
}
