import SwiftUI

struct HomeStatusIndicator: View {
  let status: HomeSessionStatus
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
