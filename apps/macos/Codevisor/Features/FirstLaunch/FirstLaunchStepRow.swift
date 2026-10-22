import CodevisorCore
import SwiftUI

struct FirstLaunchStepRow: View {
  let step: FirstLaunchStep
  let outcome: FirstLaunchStepOutcome
  let details: [String]

  var body: some View {
    HStack(spacing: 10) {
      FirstLaunchStepIndicator(outcome: outcome)
      Text(step.title)
        .lineLimit(1)
        .foregroundStyle(outcome == .pending ? .secondary : .primary)
        .layoutPriority(1)
      Spacer(minLength: 12)
      FirstLaunchStepDetail(candidates: details)
        .frame(width: Self.detailWidth, alignment: .trailing)
    }
    .frame(height: Self.height)
    .animation(.smooth(duration: 0.25), value: outcome)
  }

  private static let height: CGFloat = 22
  private static let detailWidth: CGFloat = 170
}
