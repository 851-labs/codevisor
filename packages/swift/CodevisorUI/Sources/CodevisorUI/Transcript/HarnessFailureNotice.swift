import SwiftUI
import TranscriptKit

public struct HarnessFailureNotice: View {
  private let failure: HarnessFailureStop
  private let detail: String
  private let harnessName: String?
  private let inBotConversation: Bool
  private let retry: (() -> Void)?
  private let switchAccount: () -> Void

  public init(
    failure: HarnessFailureStop,
    detail: String,
    harnessName: String?,
    inBotConversation: Bool,
    retry: (() -> Void)?,
    switchAccount: @escaping () -> Void
  ) {
    self.failure = failure
    self.detail = detail
    self.harnessName = harnessName
    self.inBotConversation = inBotConversation
    self.retry = retry
    self.switchAccount = switchAccount
  }

  public var body: some View {
    TranscriptInlineCard(
      title: title,
      state: .pending(message: detail, actions: actions),
      inBotConversation: inBotConversation,
      tone: .error
    )
  }

  private var title: String {
    switch failure {
    case .forbidden: "\(harnessName ?? "The agent") refused the request"
    case .harnessFailed: "Agent stopped with an error"
    }
  }

  private var actions: [TranscriptInlineCard.Action] {
    switch failure {
    case .forbidden:
      retryAction(emphasis: .quiet) + [switchAccountAction]
    case .harnessFailed:
      retryAction(emphasis: .primary)
    }
  }

  private var switchAccountAction: TranscriptInlineCard.Action {
    TranscriptInlineCard.Action("Switch Account", emphasis: .primary, perform: switchAccount)
  }

  private func retryAction(emphasis: TranscriptInlineCard.Action.Emphasis) -> [TranscriptInlineCard.Action] {
    guard let retry else { return [] }
    return [TranscriptInlineCard.Action("Retry", emphasis: emphasis, perform: retry)]
  }
}
