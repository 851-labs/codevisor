import CodevisorCore
import CodevisorUI
import SwiftUI

struct FirstLaunchStartingView: View {
  var body: some View {
    ProgressStepScreen(title: FirstLaunchSetupTitle.settingUp, steps: Self.steps) {
      FirstLaunchGetStartedButton(isReady: false) {}
    }
    .ignoresSafeArea()
  }

  private static let steps = FirstLaunchStep.allCases.map { step in
    ProgressStep(id: "\(step)", title: step.title, state: step == .server ? .running : .pending)
  }
}
