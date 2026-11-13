import CodevisorCore
import CodevisorUI
import SwiftUI

struct LaunchScreen: View {
  let phase: LaunchPhase
  let upgrades: LaunchUpgradeLog
  let actions: LaunchActions

  var body: some View {
    Group {
      switch phase {
      case .starting, .startingSlowly, .ready:
        LaunchStartingView(isSlow: phase == .startingSlowly)
      case let .updatingData(upgrade):
        LaunchDataUpdateView(upgrades: upgrades.including(upgrade))
      case let .failed(failure):
        LaunchFailureView(failure: failure, actions: actions)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea()
    .background(.background)
  }
}
