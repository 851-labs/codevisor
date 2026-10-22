import SwiftUI

struct FirstLaunchGetStartedButton: View {
  let isReady: Bool
  let action: () -> Void

  var body: some View {
    Button("Get Started", action: action)
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
      .disabled(!isReady)
      .opacity(isReady ? 1 : 0)
      .accessibilityHidden(!isReady)
      .animation(.smooth(duration: 0.3), value: isReady)
  }
}
