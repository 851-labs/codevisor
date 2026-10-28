import CodevisorCore
import SwiftUI

public struct SandboxStartDisclosure: View {
  let summary: SandboxStartSummary
  @Environment(\.transcriptDisclosure) private var disclosureStore

  public init(summary: SandboxStartSummary) {
    self.summary = summary
  }

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
  private var isExpanded: Bool { store.isExpanded(.sandboxStart, default: false) }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        store.toggle(.sandboxStart, default: false)
      } label: {
        header
          .contentShape(Rectangle())
      }
      .buttonStyle(TranscriptWorkedSectionButtonStyle())
      .accessibilityHint(isExpanded ? "Hides the log" : "Shows the log")
      TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          PlainOutputView(title: "Logs", text: summary.log, followsTail: summary.state == .running)
          ForEach(Array(summary.shownSteps.compactMap(\.logResource).enumerated()), id: \.offset) { _, resource in
            TranscriptBodyView(resource: resource)
          }
        }
        .padding(.top, 12)
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
