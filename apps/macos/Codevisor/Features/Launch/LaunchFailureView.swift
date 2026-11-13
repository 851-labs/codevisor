import CodevisorCore
import CodevisorUI
import SwiftUI

struct LaunchFailureView: View {
  let failure: LaunchFailure
  let actions: LaunchActions

  var body: some View {
    IconAnchoredStack {
      CodevisorAppIconView(size: 72)
      ProgressStepTitle(title: failure.title)
      Text(failure.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .frame(maxWidth: ProgressStepList.width)
      LaunchFailureButtons(failure: failure, actions: actions)
        .padding(.top, 4)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(failure.title)
  }
}
