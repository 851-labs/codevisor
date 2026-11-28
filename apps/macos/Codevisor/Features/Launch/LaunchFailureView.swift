import CodevisorCore
import CodevisorUI
import SwiftUI

struct LaunchFailureView: View {
  let failure: LaunchFailure
  let actions: LaunchActions

  var body: some View {
    LaunchMessageView(title: failure.title, message: failure.message) {
      LaunchFailureButtons(failure: failure, actions: actions)
    }
  }
}
