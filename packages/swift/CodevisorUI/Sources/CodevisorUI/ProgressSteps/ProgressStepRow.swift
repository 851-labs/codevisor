import SwiftUI

struct ProgressStepRow: View {
  let step: ProgressStep

  var body: some View {
    HStack(spacing: 10) {
      ProgressStepIndicator(state: step.state)
      Text(step.title)
        .lineLimit(1)
        .foregroundStyle(step.state == .pending ? .secondary : .primary)
        .layoutPriority(1)
      Spacer(minLength: 12)
      ProgressStepDetail(candidates: step.details)
        .frame(maxWidth: Self.detailWidth, alignment: .trailing)
    }
    .frame(height: Self.height)
    .animation(.smooth(duration: 0.2), value: step.state)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(step.title)
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    guard let detail = step.details.first else { return step.state.accessibilityValue }
    return "\(step.state.accessibilityValue), \(detail)"
  }

  private static let height: CGFloat = 22
  private static let detailWidth: CGFloat = 200
}
