import CodevisorCore
import SwiftUI
import TranscriptKit

public struct UsageLimitNotice: View {
  private let autoResume: SessionAutoResume?
  private let inBotConversation: Bool
  private let switchAccount: () -> Void
  private let cancelAutoResume: () -> Void
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?

  public init(
    autoResume: SessionAutoResume?,
    inBotConversation: Bool,
    switchAccount: @escaping () -> Void,
    cancelAutoResume: @escaping () -> Void
  ) {
    self.autoResume = autoResume
    self.inBotConversation = inBotConversation
    self.switchAccount = switchAccount
    self.cancelAutoResume = cancelAutoResume
  }

  public var body: some View {
    if autoResume?.state == .resuming {
      AssistantTurnActivityView(AssistantTurnActivity(message: "Resuming…", followsResponse: false))
    } else {
      TranscriptInlineCard(
        title: "Usage limit reached",
        state: .pending(message: message, actions: actions),
        inBotConversation: inBotConversation,
        tone: resumeFailed ? .error : .neutral
      )
    }
  }

  private var resumeFailed: Bool { autoResume?.state == .failed }

  private var message: String {
    guard let autoResume else { return "Won't resume automatically." }
    if resumeFailed { return "Couldn't resume." }
    return UsageLimitResumeText.detail(resumesAt: autoResume.resumesAt, now: environment?.now() ?? .now)
  }

  private var actions: [TranscriptInlineCard.Action] {
    let switchAccount = TranscriptInlineCard.Action("Switch Account", emphasis: .primary, perform: switchAccount)
    guard autoResume != nil, !resumeFailed else { return [switchAccount] }
    return [TranscriptInlineCard.Action("Don't Resume", emphasis: .quiet, perform: cancelAutoResume), switchAccount]
  }
}
