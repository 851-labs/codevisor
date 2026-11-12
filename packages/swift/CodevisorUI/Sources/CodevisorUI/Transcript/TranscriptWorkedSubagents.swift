import ACPKit
import CodevisorCore
import SwiftUI

struct TranscriptWorkedSubagents: View {
  let calls: [ToolCall]
  let isTurnActive: Bool
  @Environment(\.transcriptController) private var controller
  @Environment(\.runningSubagentToolCallIds) private var inheritedRunningIDs

  var body: some View {
    chips
      .environment(\.runningSubagentToolCallIds, controller?.runningSubagentToolCallIds ?? inheritedRunningIDs)
  }

  private var chips: some View {
    #if os(iOS)
      SubagentChips(calls: calls, isTurnActive: isTurnActive).font(.callout)
    #else
      SubagentChips(calls: calls, isTurnActive: isTurnActive)
    #endif
  }
}
