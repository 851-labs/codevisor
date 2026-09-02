import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Chrome setup must happen from Codevisor on the computer running the chat.
/// iOS keeps the durable question visible as a handoff: opening the same chat
/// on that computer exposes the installer, and the server resolves this card
/// everywhere when Chrome connects.
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

            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finish Chrome setup on the computer")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Connect Chrome on the computer", systemImage: "puzzlepiece.extension")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Button {
                Task { await controller.cancelQuestion() }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .scaledFrame(width: 28, height: 28, relativeTo: .caption)
                    .expandedHitTarget(base: 28)
            }
            .buttonStyle(HoverIconButtonStyle(shape: .circle))
            .accessibilityLabel("Dismiss Chrome setup")
        }
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.5))
        )
    }

    private var footer: some View {
        HStack {
            if let backOptionLabel = question.backOptionLabel {
                Button {
                    Task {
                        await controller.answerQuestion(answers: [
                            question.id: QuestionAnswerEntry(answers: [backOptionLabel])
                        ])
                    }
                } label: {
                    Image(systemName: "arrow.left")
                        .composerCircleActionLabel(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Browser Choices")
                .accessibilityHint("Returns to the browser choices")
            }
            Spacer(minLength: 0)
        }
    }
}
