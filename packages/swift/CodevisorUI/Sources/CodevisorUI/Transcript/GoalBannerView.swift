import ACPKit
import CodevisorCore
import SwiftUI

public struct GoalBannerView: View {
  private var cardStyle = ComposerCardStyle()
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var controller: SessionController
  let goal: SessionGoal
  var glassNamespace: Namespace.ID? = nil

  public init(controller: SessionController, goal: SessionGoal, glassNamespace: Namespace.ID? = nil) {
    self.controller = controller
    self.goal = goal
    self.glassNamespace = glassNamespace
  }

  @State private var isClearConfirmationPresented = false

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "target")
        .font(.caption)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(goal.objective)
          .font(.callout.weight(.medium))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
        usageLine
      }
      Spacer(minLength: 8)
      controls
    }
    .padding(ComposerCardStyle.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .composerGlassSurface(
      shape: cardStyle.shape,
      id: .goal,
      in: glassNamespace
    )
    .confirmationDialog(
      "Clear this goal?",
      isPresented: $isClearConfirmationPresented
    ) {
      Button("Clear Goal", role: .destructive) {
        Task { await controller.clearGoal() }
      }
    } message: {
      Text("The agent stops working toward “\(goal.objective)”.")
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Goal: \(goal.objective), \(statusText)")
  }

  @ViewBuilder
  private var usageLine: some View {
    if let usageText = GoalPresentation.usageText(for: goal) {
      Text(usageText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var controls: some View {
    HStack(spacing: 6) {
      if goal.status == .active {
        iconButton("pause.fill", help: "Pause goal") {
          Task { await controller.pauseGoal() }
        }
      } else if goal.status != .complete {
        iconButton("play.fill", help: "Resume goal") {
          Task { await controller.resumeGoal() }
        }
      }
      iconButton("pencil", help: "Edit goal — loads it into the composer") {
        controller.editGoal()
      }
      iconButton("xmark", help: "Clear goal") {
        isClearConfirmationPresented = true
      }
    }
  }

  private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.caption)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(help)
  }

  private var statusText: String {
    GoalPresentation.statusText(for: goal.status)
  }
}
