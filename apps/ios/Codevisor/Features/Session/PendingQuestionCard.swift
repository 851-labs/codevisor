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
    Button {
      controller.presentedQuestionId = request.questionId
    } label: {
      TranscriptQuestionContainer(inBotConversation: inBotConversation) {
        HStack(spacing: 12) {
          Image(systemName: "questionmark.bubble.fill")
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 28)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.body.weight(.semibold))
            Text(request.questions.first?.question ?? "")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .disabled(!isAnswerable)
    .accessibilityHint("Opens the questions")
  }

  private var title: String {
    let count = request.questions.count
    return count == 1 ? "The agent has a question" : "The agent has \(count) questions"
  }
}
