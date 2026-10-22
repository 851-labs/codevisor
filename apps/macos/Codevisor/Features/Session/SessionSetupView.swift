import AppKit
import CodevisorCore
import StreamMarkdown
import SwiftUI
import CodevisorUI

struct SessionSetupView: View {
  let phases: [SessionSetupPhase]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(phases) { phase in
        SessionSetupPhaseView(phase: phase)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionSetupPhaseView: View {
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
                message,
                font: .preferredFont(forTextStyle: .callout),
                foregroundColor: .systemRed,
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
      case .running:
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
    case .running:
      HStack(spacing: 6) {
        Text("\(phase.activeTitle)…")
          .shimmering()
        TimelineView(.periodic(from: phase.startedAt, by: 1)) { context in
          Text(format(elapsedSeconds(to: context.date)))
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
    guard let duration = phase.duration, duration >= 1 else {
      return "\(phase.completedTitle) in a moment"
    }
    return "\(phase.completedTitle) in \(format(Int(duration.rounded())))"
  }

  private func elapsedSeconds(to date: Date) -> Int {
    max(0, Int(date.timeIntervalSince(phase.startedAt)))
  }

  private func format(_ seconds: Int) -> String {
    seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }
}

#if DEBUG
  #Preview("Setup phases") {
    var running = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-12))
    running.appendLog(stream: "stderr", line: "Preparing worktree (new branch 'codevisor/fearless-raven')")
    running.appendLog(stream: "stdout", line: "git submodule update: cloning 12 repositories…")

    var done = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-64))
    done.succeed(durationMs: 60_000)

    var failed = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-3))
    failed.appendLog(stream: "stderr", line: "fatal: a branch named 'codevisor/fix-auth' already exists")
    failed.fail(message: "fatal: a branch named 'codevisor/fix-auth' already exists")

    return ScrollView {
      SessionSetupView(phases: [running, done, failed])
        .padding()
    }
    .frame(width: 640, height: 420)
  }
#endif
