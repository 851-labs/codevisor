import CodevisorCore
import SwiftUI

struct FirstLaunchPreparationView: View {
  let setup: FirstLaunchSetup
  let failure: String?
  let retry: () -> Void
  let showDataFolder: () -> Void

  var body: some View {
    FirstLaunchSetupView(setup: setup, phase: .covering, composerFrame: nil, composerCornerRadius: 0) {
      if let failure {
        FirstLaunchLocalDataFailure(message: failure, retry: retry, showDataFolder: showDataFolder)
      } else {
        FirstLaunchGetStartedButton(isReady: false) {}
      }
    }
  }
}
