import CodevisorCore
import SwiftUI

public struct SandboxStartDisclosure<Step: View>: View {
  let summary: SandboxStartSummary
  let step: (SessionSetupPhase) -> Step
  @State private var isExpanded = false

  public init(summary: SandboxStartSummary, @ViewBuilder step: @escaping (SessionSetupPhase) -> Step) {
    self.summary = summary
    self.step = step
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
      if !isExpanded, let current = summary.currentStep {
        Text("\(current.activeTitle)…")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .padding(.top, 3)
          .transaction { $0.animation = nil }
      }
      TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(summary.steps) { phase in
            step(phase)
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
    case .succeeded:
      Text(summary.title)
    case .failed:
      Label(summary.title, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }
}
