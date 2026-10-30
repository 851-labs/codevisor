import SwiftUI

public struct SandboxPausedNotice: View {
  private let wakeFailure: String?
  private let wake: () -> Void

  public init(wakeFailure: String?, wake: @escaping () -> Void) {
    self.wakeFailure = wakeFailure
    self.wake = wake
  }

  public var body: some View {
    TranscriptInlineCard(
      title: "Sandbox paused",
      state: .pending(
        message: wakeFailure ?? "It paused after a while with no chat running. Its files are kept.",
        actions: [TranscriptInlineCard.Action("Wake", emphasis: .primary, perform: wake)]
      ),
      inBotConversation: false,
      tone: wakeFailure == nil ? .neutral : .error
    )
  }
}
