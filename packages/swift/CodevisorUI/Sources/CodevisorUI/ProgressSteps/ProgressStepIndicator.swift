import SwiftUI

struct ProgressStepIndicator: View {
  let state: ProgressStepState

  var body: some View {
    ZStack {
      Image(systemName: "circle.dotted")
        .foregroundStyle(.tertiary)
        .opacity(state == .pending ? 1 : 0)
      ProgressView()
        .controlSize(.small)
        .opacity(state == .running ? 1 : 0)
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .opacity(state == .done ? 1 : 0)
      Image(systemName: "minus.circle")
        .foregroundStyle(.tertiary)
        .opacity(state == .skipped ? 1 : 0)
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .opacity(state == .failed ? 1 : 0)
    }
    .font(.system(size: 15))
    .frame(width: 18, height: 18)
    .accessibilityHidden(true)
  }
}
