import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

struct SessionSetupView: View {
  let phases: [SessionSetupPhase]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(SessionSetupGroup.grouping(phases)) { group in
        switch group {
        case let .phase(phase): SessionSetupPhaseView(phase: phase)
        case let .sandbox(summary): SandboxStartDisclosure(summary: summary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SessionSetupPhaseView: View {
  let phase: SessionSetupPhase
  @State private var isExpanded: Bool
  @State private var hasAutoExpandedFailure: Bool

  init(phase: SessionSetupPhase) {
    self.phase = phase
    let failed = phase.failureMessage != nil
    _isExpanded = State(initialValue: failed)
    _hasAutoExpandedFailure = State(initialValue: failed)
  }

  private var hasDetail: Bool {
    !phase.logs.isEmpty || phase.failureMessage != nil || phase.logResource != nil
  }

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
        VStack(alignment: .leading, spacing: 8) {
          if let message = phase.failureMessage {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
              SelectableTextView(
                attributedText: NSAttributedString(
                  string: message,
                  attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .callout),
                    .foregroundColor: UIColor(Color.red),
                  ]
                ),
                fillsWidth: true
              )
            }
            .foregroundStyle(.red)
          }
          if let resource = phase.logResource {
            TranscriptBodyView(resource: resource)
          } else if !phase.logs.isEmpty {
            PlainOutputView(
              title: "Logs",
              text: phase.logs.map(\.text).joined(separator: "\n"),
              followsTail: phase.isRunning
            )
          }
        }
        .padding(.top, 12)
      }
    }
    .onChange(of: phase.outcome) { _, outcome in
      switch outcome {
      case .failed:
        guard !hasAutoExpandedFailure else { return }
        hasAutoExpandedFailure = true
        isExpanded = true
      case .succeeded:
        isExpanded = false
      case .running, .pending:
        break
      }
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
    .transaction { transaction in
      transaction.animation = nil
    }
  }

  @ViewBuilder
  private var label: some View {
    switch phase.outcome {
    case .pending:
      Text(phase.upcomingTitle)
        .foregroundStyle(.tertiary)
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
      Text(completedTitle)
    case .failed:
      Label(phase.failedTitle, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  private var completedTitle: String {
    SetupDuration.completed(phase.completedTitle, after: phase.duration)
  }
}
