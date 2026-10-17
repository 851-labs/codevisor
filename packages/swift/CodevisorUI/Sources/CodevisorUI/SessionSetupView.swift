#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif
import CodevisorCore
import StreamMarkdown
import SwiftUI

public struct SessionSetupView: View {
  private let phases: [SessionSetupPhase]

  public init(phases: [SessionSetupPhase]) {
    self.phases = phases
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(phases) { phase in
        SessionSetupPhaseView(phase: phase)
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
              #if canImport(AppKit)
                SelectableTextView(
                  message,
                  font: .preferredFont(forTextStyle: .callout),
                  foregroundColor: .systemRed,
                  fillsWidth: true
                )
              #elseif canImport(UIKit)
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
              #endif
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
