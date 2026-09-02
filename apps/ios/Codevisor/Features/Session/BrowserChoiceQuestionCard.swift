import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// A deterministic browser picker with the same select-then-continue contract
/// as macOS. Browser selection is navigation inside the held tool call, not a
/// chat message, so the primary action uses an explicit Continue label.
struct BrowserChoiceQuestionCard: View {
    @Bindable var controller: SessionController
    let question: QuestionSpec

    @State private var selectedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Text(question.question)
                .font(.subheadline.weight(.medium))

            VStack(spacing: 2) {
                ForEach(question.options) { option in
                    optionRow(option)
                }
            }

            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a browser")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Browser Use", systemImage: "globe")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
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
            .accessibilityLabel("Dismiss browser choices")
        }
    }

    private func optionRow(_ option: QuestionOption) -> some View {
        let isSelected = selectedLabel == option.label
        return Button {
            selectedLabel = option.label
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                continueWithSelection()
            } label: {
                continueLabel
            }
            .buttonStyle(.plain)
            .disabled(selectedLabel == nil || controller.isResolvingQuestion)
            .accessibilityLabel(controller.isResolvingQuestion ? "Continuing" : "Continue")
            .accessibilityHint("Uses the selected browser for this chat")
        }
    }

    @ViewBuilder
    private var continueLabel: some View {
        if controller.isResolvingQuestion {
            ProgressView()
                .controlSize(.small)
                .composerCircleActionLabel(.primary, isEnabled: false)
        } else {
            Image(systemName: "arrow.right")
                .composerCircleActionLabel(.primary, isEnabled: selectedLabel != nil)
        }
    }

    private func continueWithSelection() {
        guard let selectedLabel, !controller.isResolvingQuestion else { return }
        Task {
            await controller.answerQuestion(answers: [
                question.id: QuestionAnswerEntry(answers: [selectedLabel])
            ])
        }
    }
}
