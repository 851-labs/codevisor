import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct PendingQuestionCard: View {
  let controller: SessionController
  let request: QuestionRequest
  let inBotConversation: Bool

  private var isAnswerable: Bool {
    controller.transcriptQuestion?.questionId == request.questionId
  }

  private var draft: QuestionDraft { controller.questionDraft(for: request) }

  var body: some View {
    TranscriptQuestionContainer(inBotConversation: inBotConversation) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, spec in
          if index > 0 { Divider().padding(.leading, 34) }
          PendingQuestionRow(index: index, question: spec.question, answer: draft.answers[spec.id]) {
            open(at: index)
          }
        }
      }
      .padding(.vertical, -6)
    }
    .disabled(!isAnswerable)
  }

  private func open(at index: Int) {
    draft.show(page: index)
    controller.presentedQuestionId = request.questionId
  }
}

private struct PendingQuestionRow: View {
  let index: Int
  let question: String
  let answer: QuestionAnswerEntry?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: answer == nil ? "\(index + 1).circle" : "checkmark.circle.fill")
          .font(.body)
          .foregroundStyle(answer == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
          .frame(width: 24)
          .accessibilityLabel(answer == nil ? "Not answered" : "Answered")
        VStack(alignment: .leading, spacing: 2) {
          Text(question)
            .font(.subheadline.weight(.medium))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          if let answerText {
            Text(answerText)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens this question")
  }

  private var answerText: String? {
    guard let answer else { return nil }
    return ([answer.answers.joined(separator: ", ")] + [answer.note].compactMap(\.self)).joined(separator: " — ")
  }
}
