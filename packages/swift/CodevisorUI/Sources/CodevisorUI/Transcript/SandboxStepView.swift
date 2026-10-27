import CodevisorCore
import SwiftUI

struct SandboxStepView: View {
  let phase: SessionSetupPhase
  @State private var isExpanded = false

  private var output: String {
    var lines = phase.logs.map(\.text)
    if let failure = phase.failureMessage, lines.last != failure { lines.append(failure) }
    return lines.joined(separator: "\n")
  }

  private var hasDetail: Bool { phase.logResource != nil || !output.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if hasDetail {
        Button {
          isExpanded.toggle()
        } label: {
          header(showsChevron: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(TranscriptWorkedSectionButtonStyle())
      } else {
        header(showsChevron: false)
      }
      TranscriptDisclosureContentReveal(isExpanded: isExpanded && hasDetail) {
        detail.padding(.top, 12)
      }
    }
    .onChange(of: phase.outcome) { _, outcome in
      if outcome == .succeeded { isExpanded = false }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let resource = phase.logResource {
      VStack(alignment: .leading, spacing: 8) {
        TranscriptBodyView(resource: resource)
        if let failure = phase.failureMessage {
          PlainOutputView(title: "Logs", text: failure)
        }
      }
    } else {
      PlainOutputView(title: "Logs", text: output, followsTail: phase.isRunning)
    }
  }

  private func header(showsChevron: Bool) -> some View {
    HStack(spacing: 6) {
      label
      if showsChevron {
        TranscriptDisclosureChevron(expanded: isExpanded)
      }
      Spacer(minLength: 0)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .transaction { $0.animation = nil }
  }

  @ViewBuilder
  private var label: some View {
    switch phase.outcome {
    case .pending:
      Text(phase.upcomingTitle)
    case .running:
      HStack(spacing: 6) {
        Text("\(phase.activeTitle)…")
          .shimmering()
        TimelineView(.periodic(from: phase.startedAt, by: 1)) { context in
          Text(SetupDuration.elapsed(since: phase.startedAt, to: context.date))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }
    case .succeeded:
      Text(SetupDuration.completed(phase.completedTitle, after: phase.duration))
    case .failed:
      Text(phase.failedTitle)
    }
  }
}
