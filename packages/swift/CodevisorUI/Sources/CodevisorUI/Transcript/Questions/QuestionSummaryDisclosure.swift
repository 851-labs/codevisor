import CodevisorCore
import SwiftUI

struct QuestionSummaryDisclosure: View {
  let summary: TranscriptQuestionSummary
  let questionId: String

  @Environment(\.transcriptDisclosure) private var disclosureStore

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
  private var key: TranscriptDisclosureStore.Key { .questionSummary(questionId) }
  private var isExpanded: Bool { store.isExpanded(key, default: false) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        store.toggle(key, default: false)
      } label: {
        QuestionSummaryDisclosureRow(title: summary.title, isExpanded: isExpanded)
      }
      .buttonStyle(.plain)
      .accessibilityHint(isExpanded ? "Hides the answers" : "Shows the answers")
      TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
        QuestionSummaryAnswers(lines: summary.lines)
          .padding(.top, 10)
      }
    }
  }
}

private struct QuestionSummaryDisclosureRow: View {
  let title: String
  let isExpanded: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      QuestionSummaryTitle(text: title)
      TranscriptDisclosureChevron(expanded: isExpanded)
    }
    .contentShape(Rectangle())
  }
}
