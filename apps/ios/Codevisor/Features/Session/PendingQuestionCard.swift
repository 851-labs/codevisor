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

  var body: some View {
    TranscriptQuestionContainer(inBotConversation: inBotConversation) {
      Button {
        controller.presentedQuestionId = request.questionId
      } label: {
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(caption)
              .font(.footnote.weight(.medium))
              .foregroundStyle(.secondary)
            Text(request.questions.first?.question ?? "")
              .font(.headline)
              .foregroundStyle(.primary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          AnswerPill()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!isAnswerable)
      .accessibilityHint("Opens the questions")
    }
  }

  private var caption: String {
    let count = request.questions.count
    let answered = controller.questionDraft(for: request).answers.count
    let questions = count == 1 ? "Question" : "\(count) questions"
    return answered == 0 ? questions : "\(questions) · \(answered) answered"
  }
}

private struct AnswerPill: View {
  var body: some View {
    Text("Answer")
      .font(.body.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 18)
      .frame(minHeight: 36)
      .background(Capsule().fill(Color.accentColor))
      .accessibilityHidden(true)
  }
}
