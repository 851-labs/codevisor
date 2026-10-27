import SwiftUI
import TranscriptKit

public struct AttributedUserMessage<Bubble: View>: View {
  let message: UserMessage
  let bubble: Bubble

  public init(_ message: UserMessage, @ViewBuilder bubble: () -> Bubble) {
    self.message = message
    self.bubble = bubble()
  }

  public var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      bubble
      UserMessageAttributionLabel(message.attribution)
    }
  }
}
