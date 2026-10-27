import CodevisorCore
import SwiftUI

public struct SandboxStartFailureNotice: View {
  private let message: String
  private let inBotConversation: Bool
  private let retry: () -> Void

  public init(message: String, inBotConversation: Bool, retry: @escaping () -> Void) {
    self.message = message
    self.inBotConversation = inBotConversation
    self.retry = retry
  }

  public var body: some View {
    TranscriptInlineCard(
      title: "Couldn't start sandbox",
      state: .pending(
        message: ErrorMessageSummary(message).summary,
        actions: [TranscriptInlineCard.Action("Retry", emphasis: .primary, perform: retry)]
      ),
      inBotConversation: inBotConversation,
      tone: .error
    )
  }
}
