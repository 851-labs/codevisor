import SwiftUI

struct QuestionSummaryAnswers: View {
  let lines: [TranscriptQuestionSummary.Line]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(lines) { line in
        QuestionSummaryAnswer(line: line)
      }
    }
  }
}

private struct QuestionSummaryAnswer: View {
  let line: TranscriptQuestionSummary.Line

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(line.question)
        .font(.callout.weight(.semibold))
      Text(line.answer.text)
        .font(.callout)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
