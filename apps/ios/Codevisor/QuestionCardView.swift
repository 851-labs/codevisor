import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// A blocking agent question as the composer card's content — the macOS
/// QuestionPickerContent on a phone: the composer's one glass card morphs
/// into this while a question is active. One question at a time with arrow
/// pagination, selections and notes accumulated across questions and
/// submitted once, an "Other" row backed by a note field, and skipping
/// allowed (only Other demands text). The common case — one single-select
/// question — answers on a single tap. The hosting ComposerBar owns the
/// glass surface and the "Submitting response…" overlay.
struct QuestionCardView: View {
    @Bindable var controller: SessionController
    let request: QuestionRequest

    @State private var questionIndex = 0
    @State private var selections: [String: Set<String>] = [:]
    @State private var notes: [String: String] = [:]

    /// Sentinel mirroring macOS: the synthetic "Other" row's stored label.
    private static let otherSentinel = "__other__"

    private var question: QuestionSpec? {
        guard request.questions.indices.contains(questionIndex) else { return nil }
        return request.questions[questionIndex]
    }

    private var isLastQuestion: Bool {
        questionIndex >= request.questions.count - 1
    }

    private var isSingleTapRequest: Bool {
        request.questions.count == 1
            && request.questions[0].multiSelect != true
            && !request.questions[0].options.isEmpty
            && request.questions[0].allowsOther != true
    }

    /// Unanswered questions are allowed (macOS parity); only a selected
    /// "Other" demands its text.
    private var isSubmittable: Bool {
        for spec in request.questions {
            if (selections[spec.id] ?? []).contains(Self.otherSentinel),
               (notes[spec.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let message = request.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let question {
                Text(question.question)
                    .font(.subheadline.weight(.medium))

                optionList(question)
                notesEditor(question)
            }

            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Action required", systemImage: "questionmark.bubble")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            Spacer()
            if request.questions.count > 1 {
                Text("\(questionIndex + 1) of \(request.questions.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Button {
                Task { await controller.cancelQuestion() }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(HoverIconButtonStyle(shape: .circle))
            .accessibilityLabel("Dismiss question")
        }
    }

    // MARK: - Options

    @ViewBuilder
    private func optionList(_ spec: QuestionSpec) -> some View {
        let options = spec.options
        // Long option lists scroll inside the card instead of growing it
        // past the screen.
        let list = VStack(spacing: 2) {
            ForEach(options) { option in
                optionRow(
                    spec: spec,
                    label: option.label,
                    title: option.label,
                    description: option.description
                )
            }
            if spec.allowsOther == true {
                optionRow(
                    spec: spec,
                    label: Self.otherSentinel,
                    title: "Other",
                    description: nil
                )
            }
        }
        if options.count > 6 {
            ScrollView {
                list
            }
            .frame(maxHeight: 280)
        } else {
            list
        }
    }

    private func optionRow(
        spec: QuestionSpec,
        label: String,
        title: String,
        description: String?
    ) -> some View {
        let isSelected = (selections[spec.id] ?? []).contains(label)
        return Button {
            activate(label, spec: spec)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let description, !description.isEmpty {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Toggle in multi-select, replace otherwise; the single-tap fast path
    /// submits immediately.
    private func activate(_ label: String, spec: QuestionSpec) {
        if isSingleTapRequest {
            submit([spec.id: QuestionAnswerEntry(answers: [label])])
            return
        }
        var set = selections[spec.id] ?? []
        if spec.multiSelect == true {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        selections[spec.id] = set
    }

    // MARK: - Notes

    /// Always-mounted note field, macOS-style: required text when Other is
    /// selected, an optional note otherwise.
    @ViewBuilder
    private func notesEditor(_ spec: QuestionSpec) -> some View {
        let otherSelected = (selections[spec.id] ?? []).contains(Self.otherSentinel)
        TextField(
            otherSelected ? "Type your answer (required)" : "Add a note (optional)",
            text: Binding(
                get: { notes[spec.id] ?? "" },
                set: { notes[spec.id] = $0 }
            ),
            axis: .vertical
        )
        .font(.subheadline)
        .lineLimit(1...4)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.tertiarySystemFill).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    otherSelected ? Color.accentColor : Color.clear,
                    lineWidth: 1
                )
        )
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if !isSingleTapRequest {
            HStack(spacing: 10) {
                if let question, let backLabel = question.backOptionLabel {
                    // A provider-supplied back action answers directly.
                    Button {
                        submit([question.id: QuestionAnswerEntry(answers: [backLabel])])
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                } else if questionIndex > 0 {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { questionIndex -= 1 }
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Previous question")
                }
                Spacer()
                if isLastQuestion {
                    Button {
                        submitCollected()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!isSubmittable)
                    .accessibilityLabel("Submit answers")
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { questionIndex += 1 }
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Next question")
                }
            }
        }
    }

    // MARK: - Submit

    /// Builds one entry per answered question: real labels as answers, the
    /// note attached, and a lone "Other" answered by its note text.
    private func submitCollected() {
        var entries: [String: QuestionAnswerEntry] = [:]
        for spec in request.questions {
            var labels = (selections[spec.id] ?? []).subtracting([Self.otherSentinel])
            let note = (notes[spec.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let otherSelected = (selections[spec.id] ?? []).contains(Self.otherSentinel)
            if otherSelected, !note.isEmpty, labels.isEmpty {
                labels = [note]
            }
            guard !labels.isEmpty || !note.isEmpty else { continue }
            entries[spec.id] = QuestionAnswerEntry(
                answers: Array(labels),
                note: otherSelected ? nil : (note.isEmpty ? nil : note)
            )
        }
        guard !entries.isEmpty else { return }
        submit(entries)
    }

    private func submit(_ entries: [String: QuestionAnswerEntry]) {
        Task { await controller.answerQuestion(answers: entries) }
    }
}
