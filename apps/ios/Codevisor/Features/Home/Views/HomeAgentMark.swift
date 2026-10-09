import CodevisorCore
import SwiftUI

/// An agent's state, or its harness's icon at rest, as chat rows show them
/// everywhere.
struct HomeAgentMark: View {
  let status: AgentStatus
  let harnessId: String?
  var size: CGFloat = 18

  var body: some View {
    Group {
      if status == .idle {
        HarnessIconView(harnessId: harnessId ?? "", fallbackSymbolName: "text.bubble", size: size)
          .foregroundStyle(.secondary)
      } else {
        HomeStatusIndicator(status: HomeSessionStatus(status))
      }
    }
    .frame(width: 20)
  }
}
