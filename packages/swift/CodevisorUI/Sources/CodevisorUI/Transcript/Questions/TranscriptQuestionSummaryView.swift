import SwiftUI
import TranscriptKit

public struct TranscriptQuestionSummaryView: View {
  let questionId: String
  let summary: TranscriptQuestionSummary
  let inBotConversation: Bool

  public init(question: TranscriptQuestion, inBotConversation: Bool) {
    questionId = question.request.questionId
    summary = TranscriptQuestionSummary(question)
    self.inBotConversation = inBotConversation
  }

  private var canExpand: Bool { summary.status == .answered && !summary.lines.isEmpty }

  public var body: some View {
    HStack(spacing: 0) {
      Group {
        if canExpand {
          QuestionSummaryDisclosure(summary: summary, questionId: questionId)
        } else {
          QuestionSummaryTitle(text: summary.title)
        }
      }
      .padding(.horizontal, ComposerCardStyle.contentPadding)
      .padding(.vertical, TranscriptInlineCardMetrics.resolvedVerticalPadding + 2)
      .modifier(TranscriptInlineCardSurface(inBotConversation: inBotConversation))
      .frame(maxWidth: TranscriptInlineCardMetrics.maxWidth, alignment: .leading)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain)
  }
}

struct QuestionSummaryTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout.weight(.semibold))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
