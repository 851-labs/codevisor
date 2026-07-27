import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// A blocking agent question rendered above the composer: option buttons per
/// question, free-text where allowed, submitted through the shared
/// SessionController answer path. The common phone case — one question,
/// single-select — answers on a single tap; multi-question and multi-select
/// requests collect selections and submit together.
struct QuestionCardView: View {
    @Bindable var controller: SessionController
    let request: QuestionRequest

    @State private var selections: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]

    private var isSingleTapRequest: Bool {
        request.questions.count == 1
            && request.questions[0].multiSelect != true
            && !request.questions[0].options.isEmpty
    }

    private var canSubmit: Bool {
        request.questions.allSatisfy { spec in
            !(selections[spec.id] ?? []).isEmpty
                || !(freeText[spec.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Action required", systemImage: "questionmark.bubble")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    Task { await controller.cancelQuestion() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverIconButtonStyle(shape: .circle))
            }

            if let message = request.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(request.questions) { spec in
                questionSection(spec)
            }

            if !isSingleTapRequest {
                Button {
                    submitCollected()
                } label: {
                    if controller.isResolvingQuestion {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Submit")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || controller.isResolvingQuestion)
            }
        }
        .padding(12)
        .composerGlassSurface(cornerRadius: ComposerGlassStyle.accessoryCornerRadius)
        .padding(.horizontal, 10)
        .disabled(controller.isResolvingQuestion && isSingleTapRequest)
    }

    @ViewBuilder
    private func questionSection(_ spec: QuestionSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = spec.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(spec.question)
                .font(.subheadline)

            ForEach(spec.options) { option in
                optionButton(spec: spec, option: option)
            }

            if spec.allowsOther {
                TextField(
                    spec.options.isEmpty ? "Answer" : "Other…",
                    text: Binding(
                        get: { freeText[spec.id] ?? "" },
                        set: { freeText[spec.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .submitLabel(.send)
                .onSubmit {
                    if isSingleTapRequest || request.questions.count == 1 {
                        submitCollected()
                    }
                }
            }
        }
    }

    private func optionButton(spec: QuestionSpec, option: QuestionOption) -> some View {
        let isSelected = (selections[spec.id] ?? []).contains(option.label)
        return Button {
            if isSingleTapRequest {
                submit([spec.id: QuestionAnswerEntry(answers: [option.label])])
            } else if spec.multiSelect == true {
                var set = selections[spec.id] ?? []
                if isSelected { set.remove(option.label) } else { set.insert(option.label) }
                selections[spec.id] = set
            } else {
                selections[spec.id] = [option.label]
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline)
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
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submitCollected() {
        var entries: [String: QuestionAnswerEntry] = [:]
        for spec in request.questions {
            let selected = selections[spec.id] ?? []
            let typed = (freeText[spec.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty {
                entries[spec.id] = QuestionAnswerEntry(answers: Array(selected))
            } else if !typed.isEmpty {
                entries[spec.id] = QuestionAnswerEntry(answers: [typed])
            }
        }
        guard !entries.isEmpty else { return }
        submit(entries)
    }

    private func submit(_ entries: [String: QuestionAnswerEntry]) {
        Task { await controller.answerQuestion(answers: entries) }
    }
}
