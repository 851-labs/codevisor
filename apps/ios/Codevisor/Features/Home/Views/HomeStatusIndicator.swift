import SwiftUI

/// Messages-style status gutter shared by agent rows and collapsed workspace
/// summaries. The transparent idle state preserves alignment in every row.
struct HomeStatusIndicator: View {
  let status: HomeSessionStatus
  /// On an accent-filled sidebar selection the blue unread dot would vanish.
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Group {
      switch status {
      case .error:
        Circle().fill(.red).frame(width: 8, height: 8)
      case .actionRequired:
        Circle().fill(.orange).frame(width: 8, height: 8)
      case .unread:
        Circle().fill(backgroundProminence == .increased ? Color.white : .blue).frame(width: 8, height: 8)
      case .inProgress:
        AgentActivityIndicator()
      case .idle:
        Color.clear
      }
    }
  }
}
