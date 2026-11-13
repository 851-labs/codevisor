import CodevisorCore
import SwiftUI

public struct TranscriptEventRow: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let marker: TranscriptEventMarker
  let inBotConversation: Bool

  public init(marker: TranscriptEventMarker, inBotConversation: Bool) {
    self.marker = marker
    self.inBotConversation = inBotConversation
  }

  public var body: some View {
    let agents = TranscriptEventAgents(sessions: environment?.projectList.sessions ?? [], bots: environment?.bots)
    let summary = TranscriptEventSummary(marker: marker, agents: agents)
    if inBotConversation, let threadID = marker.threadID {
      TranscriptThreadStamp(threadID: threadID, summary: .thread(marker, agents: agents))
    } else if inBotConversation {
      TranscriptEventStamp(marker: marker, summary: summary)
    } else {
      TranscriptEventDivider(marker: marker, summary: summary)
    }
  }
}
