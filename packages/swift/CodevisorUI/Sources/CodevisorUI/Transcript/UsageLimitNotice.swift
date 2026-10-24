import SwiftUI
import TranscriptKit

public struct UsageLimitNotice: View {
  private let autoResume: SessionAutoResume?
  private let inBotConversation: Bool
  private let switchAccount: () -> Void
  private let cancelAutoResume: () -> Void
  private let now: Date?

  public init(
    autoResume: SessionAutoResume?,
    inBotConversation: Bool,
    now: Date? = nil,
    switchAccount: @escaping () -> Void,
    cancelAutoResume: @escaping () -> Void
  ) {
    self.now = now
    self.autoResume = autoResume
    self.inBotConversation = inBotConversation
    self.switchAccount = switchAccount
    self.cancelAutoResume = cancelAutoResume
  }

  public var body: some View {
    TranscriptInlineCard(
      title: "Usage limit reached",
      state: .pending(message: message, actions: actions),
      inBotConversation: inBotConversation
    )
  }

  private var message: String {
    guard let autoResume else { return "Won't resume automatically." }
    return UsageLimitResumeText.detail(resumesAt: autoResume.resumesAt, now: now ?? .now)
  }

  private var actions: [TranscriptInlineCard.Action] {
    let switchAccount = TranscriptInlineCard.Action("Switch Account", emphasis: .primary, perform: switchAccount)
    guard autoResume != nil else { return [switchAccount] }
    return [TranscriptInlineCard.Action("Don't Resume", emphasis: .quiet, perform: cancelAutoResume), switchAccount]
  }
}
