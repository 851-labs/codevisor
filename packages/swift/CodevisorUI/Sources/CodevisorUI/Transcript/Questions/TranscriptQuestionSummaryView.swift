import SwiftUI
import TranscriptKit

public struct TranscriptQuestionSummaryView: View {
  let summary: TranscriptQuestionSummary
  let inBotConversation: Bool

  public init(question: TranscriptQuestion, inBotConversation: Bool) {
    summary = TranscriptQuestionSummary(question)
    self.inBotConversation = inBotConversation
  }

  public var body: some View {
    HStack(spacing: 0) {
      QuestionSummaryContent(summary: summary)
        .padding(.horizontal, ComposerCardStyle.contentPadding)
        .padding(.vertical, TranscriptInlineCardMetrics.resolvedVerticalPadding + 2)
        .modifier(TranscriptInlineCardSurface(inBotConversation: inBotConversation))
        .frame(maxWidth: TranscriptInlineCardMetrics.maxWidth, alignment: .leading)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct QuestionSummaryContent: View {
  let summary: TranscriptQuestionSummary

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: summary.symbolName)
        .foregroundStyle(summary.status == .answered ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        if summary.status != .answered || summary.lines.isEmpty {
          Text(summary.title)
            .foregroundStyle(.secondary)
        }
        ForEach(summary.lines) { line in
          QuestionSummaryLine(line: line)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .font(.callout)
  }
}

private struct QuestionSummaryLine: View {
  let line: TranscriptQuestionSummary.Line

  var body: some View {
    Text("\(Text(line.question).foregroundStyle(.secondary))  \(Text(line.answer).foregroundStyle(.primary))")
      .lineLimit(3)
  }
}
