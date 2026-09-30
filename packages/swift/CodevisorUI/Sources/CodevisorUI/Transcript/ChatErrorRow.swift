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
    ComposerNoticeRail(
      message,
      kind: .error,
      actionTitle: actionTitle,
      action: action
    )
  }
}
