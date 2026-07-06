import SwiftUI
import ACPKit

/// A compact history card for a question the user answered — the codex CLI
/// answered-question cell equivalent: the question with the chosen answer(s).
struct AnsweredQuestionView: View {
    let resolution: QuestionResolution
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(resolution.questions) { question in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "questionmark.bubble")
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.question)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(answerText(for: question))
                            .font(.callout.weight(.medium))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .accessibilityElement(children: .combine)
    }

    private func answerText(for question: QuestionSpec) -> String {
        guard let entry = resolution.answers?[question.id] else { return "No answer" }
        var parts = entry.answers
        if let note = entry.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.isEmpty ? "No answer" : parts.joined(separator: ", ")
    }
}

#Preview {
    AnsweredQuestionView(resolution: QuestionResolution(
        questionId: "q-1",
        outcome: .answered,
        questions: [
            QuestionSpec(
                id: "approach",
                header: "Approach",
                question: "Which approach should I take?",
                options: [QuestionOption(label: "MVP first")]
            )
        ],
        answers: ["approach": QuestionAnswerEntry(answers: ["MVP first"], note: "keep it lean")]
    ))
    .padding()
    .frame(width: 520)
}
