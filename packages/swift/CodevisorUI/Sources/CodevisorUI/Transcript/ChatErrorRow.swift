import CodevisorCore
import SwiftUI

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
