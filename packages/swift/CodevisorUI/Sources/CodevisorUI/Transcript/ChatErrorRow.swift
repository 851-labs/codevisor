import CodevisorCore
import SwiftUI

/// A chat error in the transcript. It is the same banner as the composer's
/// notices (`ComposerNoticeRail`) so every banner in a chat shares one shape,
/// type size, tint, and action style.
public struct ChatErrorRow: View {
  private let message: String
  private let actionTitle: String?
  private let action: (() -> Void)?

  public init(
    _ message: String,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    // Harness errors can carry a provider's whole response; the banner
    // leads with one line and keeps the rest behind Show Details.
    let error = ErrorMessageSummary(message)
    ComposerNoticeRail(
      error.summary,
      details: error.details,
      kind: .error,
      actionTitle: actionTitle,
      action: action
    )
  }
}
