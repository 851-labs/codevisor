import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Touch-sized goal summary above the composer. The compact surface is one
/// target; tapping it moves the existing objective directly into the composer
/// for editing instead of inserting an intermediate management sheet.
struct IOSGoalAccessory: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controller: SessionController
    let goal: SessionGoal
    let glassNamespace: Namespace.ID

    private var statusText: String {
        GoalPresentation.statusText(for: goal.status)
    }

    var body: some View {
        Button {
            // The accessory and composer live in one GlassEffectContainer;
            // one transaction lets their identified materials morph together.
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
            .padding(10)
            .frame(
                maxWidth: .infinity,
                minHeight: Typography.minimumInteractiveTargetSize,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .composerGlassSurface(
            cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
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
