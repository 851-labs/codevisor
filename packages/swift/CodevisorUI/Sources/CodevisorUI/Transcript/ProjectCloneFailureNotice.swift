import CodevisorCore
import SwiftUI

public struct ProjectCloneFailureNotice: View {
  private let projectName: String
  private let message: String
  private let offersSignIn: Bool
  private let inBotConversation: Bool
  private let retry: () -> Void
  private let signIn: () -> Void

  public init(
    projectName: String,
    message: String,
    offersSignIn: Bool,
    inBotConversation: Bool,
    retry: @escaping () -> Void,
    signIn: @escaping () -> Void
  ) {
    self.projectName = projectName
    self.message = message
    self.offersSignIn = offersSignIn
    self.inBotConversation = inBotConversation
    self.retry = retry
    self.signIn = signIn
  }

  public var body: some View {
    TranscriptInlineCard(
      title: "Couldn't clone \(projectName)",
      state: .pending(message: ErrorMessageSummary(message).summary, actions: actions),
      inBotConversation: inBotConversation,
      tone: .error
    )
  }

  private var actions: [TranscriptInlineCard.Action] {
    let retryAction = TranscriptInlineCard.Action("Retry", emphasis: .primary, perform: retry)
    guard offersSignIn else { return [retryAction] }
    return [TranscriptInlineCard.Action("Sign In", emphasis: .quiet, perform: signIn), retryAction]
  }
}
