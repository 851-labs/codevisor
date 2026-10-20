import SwiftUI
import TranscriptKit

public struct UsageLimitNotice: View {
  private let message: String
  private let autoResume: SessionAutoResume?
  private let switchAccount: () -> Void
  private let cancelAutoResume: () -> Void

  public init(
    _ message: String,
    autoResume: SessionAutoResume?,
    switchAccount: @escaping () -> Void,
    cancelAutoResume: @escaping () -> Void
  ) {
    self.message = message
    self.autoResume = autoResume
    self.switchAccount = switchAccount
    self.cancelAutoResume = cancelAutoResume
  }

  public var body: some View {
    if let autoResume {
      ComposerNoticeCard(
        title: "Usage limit reached",
        detail: UsageLimitResumeText.detail(resumesAt: autoResume.resumesAt),
        systemImage: "clock.fill",
        accent: .orange,
        actions: [
          .init("Don't Resume", emphasis: .quiet, perform: cancelAutoResume),
          .init(switchAccountTitle, emphasis: .primary, perform: switchAccount),
        ]
      )
    } else {
      ChatErrorRow(message, actionTitle: switchAccountTitle, action: switchAccount)
    }
  }

  private let switchAccountTitle = "Switch Account"
}
