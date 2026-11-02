import SwiftUI

struct ProgressStepTitle: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.title2.weight(.semibold))
      .multilineTextAlignment(.center)
      .contentTransition(.opacity)
      .animation(.smooth(duration: 0.3), value: title)
  }
}
