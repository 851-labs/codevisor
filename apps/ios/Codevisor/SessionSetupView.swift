import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

/// The pre-chat setup sections shown after the first user message —
/// "Setting up worktree…" / "Starting Claude Code…" — the iOS port of the
/// macOS SessionSetupView: a live timer while running, "Set up worktree in
/// 60s" when done, and an expandable body with the streamed setup logs or
/// the failure message.
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

private struct SessionSetupPhaseView: View {
    @Environment(\.theme) private var theme
    let phase: SessionSetupPhase
    @State private var isExpanded: Bool
    @State private var hasAutoExpandedFailure: Bool
    @State private var logContentHeight: CGFloat = 0

    init(phase: SessionSetupPhase) {
        self.phase = phase
        // A phase that already failed when the view mounts starts expanded so
        // the error is visible immediately.
        let failed = phase.failureMessage != nil
        _isExpanded = State(initialValue: failed)
        _hasAutoExpandedFailure = State(initialValue: failed)
    }

    private var hasDetail: Bool {
        !phase.logs.isEmpty || phase.failureMessage != nil
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
                .buttonStyle(.plain)
            } else {
                header(showsChevron: false)
            }

            TranscriptDisclosureContentReveal(isExpanded: isExpanded && hasDetail) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    if let message = phase.failureMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.callout)
                            SelectableTextView(
                                attributedText: NSAttributedString(
                                    string: message,
                                    attributes: [
                                        .font: UIFont.preferredFont(forTextStyle: .callout),
                                        .foregroundColor: UIColor(theme.statusError),
                                    ]
                                ),
                                fillsWidth: true
                            )
                        }
                        .foregroundStyle(theme.statusError)
                    }
                    if !phase.logs.isEmpty {
                        logLines
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

    /// "Setting up worktree… 12s" (shimmering, live timer) while running;
    /// "Set up worktree in 60s" once done; the failed title in warn color.
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
                .foregroundStyle(theme.statusWarn)
        }
    }

    /// Tallest the log panel grows before it scrolls (~12 rows).
    private static let logMaxHeight: CGFloat = 200

    private var logLines: some View {
        ScrollView {
            SelectableTextView(attributedText: logText, fillsWidth: true)
                .padding(10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    logContentHeight = $0
                }
        }
        // Sized to the content until it overflows, then scrolls pinned to the
        // newest line as output streams in.
        .frame(height: min(logContentHeight, Self.logMaxHeight))
        .defaultScrollAnchor(.bottom)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardQuietBackground)
        )
    }

    private var logText: NSAttributedString {
        let result = NSMutableAttributedString()
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        for (index, line) in phase.logs.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(
                NSAttributedString(
                    string: line.text,
                    attributes: [
                        .font: font,
                        .paragraphStyle: paragraph,
                        .foregroundColor: UIColor(
                            line.stream == "stderr" ? theme.textSecondary : theme.textTertiary
                        ),
                    ]
                )
            )
        }
        return result
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
