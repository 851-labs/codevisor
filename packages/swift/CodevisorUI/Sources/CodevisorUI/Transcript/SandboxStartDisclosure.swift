import CodevisorCore
import SwiftUI

public struct SandboxStartDisclosure: View {
  let summary: SandboxStartSummary
  @State private var isExpanded = false

  public init(summary: SandboxStartSummary) {
    self.summary = summary
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.toggle()
      } label: {
        header
          .contentShape(Rectangle())
      }
      .buttonStyle(TranscriptWorkedSectionButtonStyle())
      .accessibilityHint(isExpanded ? "Hides the steps" : "Shows each step")
      TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(summary.shownSteps) { phase in
            SandboxStepView(phase: phase)
          }
        }
        .padding(.top, 12)
        .padding(.leading, 14)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      title
      TranscriptDisclosureChevron(expanded: isExpanded)
      Spacer(minLength: 0)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .transaction { $0.animation = nil }
  }

  @ViewBuilder
  private var title: some View {
    switch summary.state {
    case .running:
      HStack(spacing: 6) {
        Text("\(summary.title)…")
          .shimmering()
        TimelineView(.periodic(from: summary.startedAt, by: 1)) { context in
          Text(SetupDuration.elapsed(since: summary.startedAt, to: context.date))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }
    case .succeeded, .failed:
      Text(summary.title)
    }
  }
}
