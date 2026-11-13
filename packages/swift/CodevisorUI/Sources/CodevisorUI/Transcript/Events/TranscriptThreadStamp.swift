import CodevisorCore
import SwiftUI

struct TranscriptThreadStamp: View {
  let threadID: String
  let summary: TranscriptEventSummary
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @Environment(\.transcriptController) private var controller

  var body: some View {
    Button {
      open()
    } label: {
      TranscriptEventStampLabel(summary: summary, isActive: false)
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens the thread")
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }

  private func open() {
    guard let environment, let session = controller?.serverSession,
      let bot = environment.bots.bot(forSession: session.id, serverId: session.serverId)
    else { return }

    Task { await environment.botThreads.open(threadID, of: bot) }
  }
}
