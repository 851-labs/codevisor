import CodevisorCore
import SwiftUI

struct FirstLaunchStepIndicator: View {
  let outcome: FirstLaunchStepOutcome

  var body: some View {
    ZStack {
      Image(systemName: "circle.dotted")
        .foregroundStyle(.tertiary)
        .opacity(outcome == .pending ? 1 : 0)
      ProgressView()
        .controlSize(.small)
        .opacity(outcome == .running ? 1 : 0)
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .opacity(outcome == .done ? 1 : 0)
      Image(systemName: "minus.circle")
        .foregroundStyle(.tertiary)
        .opacity(outcome == .skipped ? 1 : 0)
    }
    .font(.system(size: 15))
    .frame(width: 18, height: 18)
    .accessibilityHidden(true)
  }
}
