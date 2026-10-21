import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct BrowserExtensionQuestionCard: View {
  @Bindable var controller: SessionController
  let question: QuestionSpec

  private var isWaiting: Bool {
    question.presentation == .browserExtensionWaiting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      handoffContent
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Finish Chrome setup on the computer")
  }

  private var header: some View {
    QuestionCardHeader(
      title: "Connect Chrome on the computer",
      dismissLabel: "Dismiss Chrome setup",
      onDismiss: { Task { await controller.cancelQuestion() } }
    )
  }

  private var handoffContent: some View {
    VStack(spacing: 12) {
      if isWaiting {
        ProgressView()
          .controlSize(.regular)
          .accessibilityHidden(true)
      } else {
        Image(systemName: "desktopcomputer")
          .font(.system(size: 30, weight: .regular))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }

      VStack(spacing: 4) {
        Text("Open this chat on the computer running it")
          .font(.subheadline.weight(.medium))
        Text(
          "Install the Codevisor extension from that computer. This chat resumes automatically when Chrome connects."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 12)
    .padding(.vertical, 14)
    .background(
      ComposerCardStyle().insetShape(by: ComposerCardStyle.contentPadding)
        .fill(HierarchicalShapeStyle.quaternary.opacity(0.6))
    )
  }
}
