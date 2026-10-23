import CodevisorUI
import SwiftUI

struct FirstLaunchGetStartedButton: View {
  let isReady: Bool
  let action: () -> Void

  var body: some View {
    SheetPrimaryButton("Get Started", isEnabled: isReady, action: action)
      .controlSize(.large)
      .opacity(isReady ? 1 : 0)
      .accessibilityHidden(!isReady)
      .animation(.smooth(duration: 0.3), value: isReady)
  }
}
