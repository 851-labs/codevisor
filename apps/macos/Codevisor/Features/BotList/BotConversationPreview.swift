import CodevisorCore
import SwiftUI

struct BotConversationPreview: View {
  private static let lineCount = 2

  let conversation: BotConversation
  let isHighlighted: Bool

  var body: some View {
    Group {
      if conversation.activity == .working {
        ZStack(alignment: .topLeading) {
          Text(verbatim: " ")
            .lineLimit(Self.lineCount, reservesSpace: true)
            .hidden()
          BotTypingIndicator(isHighlighted: isHighlighted)
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
    if isHighlighted { return AnyShapeStyle(.white.opacity(0.8)) }
    switch conversation.activity {
    case .waitingOnUser: return AnyShapeStyle(.orange)
    case .failed: return AnyShapeStyle(.red)
    case .idle, .working: return AnyShapeStyle(.secondary)
    }
  }
}
