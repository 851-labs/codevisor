import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSGoalAccessory: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var cardStyle = ComposerCardStyle()
  @Bindable var controller: SessionController
  let goal: SessionGoal
  let glassNamespace: Namespace.ID

  private var statusText: String {
    GoalPresentation.statusText(for: goal.status)
  }

  var body: some View {
    Button {
      withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
        controller.editGoal()
      }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "target")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
          .scaledFrame(width: 22, relativeTo: .callout)

        VStack(alignment: .leading, spacing: 4) {
          Text(goal.objective)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)

          HStack(spacing: 5) {
            Text(statusText)
            if let usageText = GoalPresentation.usageText(for: goal) {
              Text("·")
              Text(usageText)
                .monospacedDigit()
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(ComposerCardStyle.contentPadding)
      .frame(
        maxWidth: .infinity,
        minHeight: Typography.minimumInteractiveTargetSize,
        alignment: .leading
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .composerGlassSurface(
      shape: cardStyle.shape,
      id: .goal,
      in: glassNamespace
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Goal: \(goal.objective)")
    .accessibilityValue(accessibilityValue)
    .accessibilityHint("Edits this goal in the composer")
  }

  private var accessibilityValue: String {
    let usage = GoalPresentation.usageText(for: goal)
    return [statusText, usage].compactMap { $0 }.joined(separator: ", ")
  }
}
