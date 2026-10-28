import SwiftUI

public struct TranscriptBotTypingRow: View {
  public init() {}

  public var body: some View {
    HStack {
      BotTypingBubble()
      Spacer(minLength: 0)
    }
    .suppressedDuringStreamingTextEntrance()
  }
}
