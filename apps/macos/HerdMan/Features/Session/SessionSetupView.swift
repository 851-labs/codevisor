import SwiftUI
import HerdManCore

/// The pre-chat setup sections shown at the top of a brand-new session:
/// "Setting up worktree…" / "Starting Claude Code…" rows styled like the
/// transcript's "Worked for…" disclosure — a live timer while running, a
/// final "Set up worktree in 60s" when done, and an expandable body with the
/// streamed setup logs (git output, checkout hooks) or the failure message.
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
    @Environment(\.theme) private var theme
    let phase: SessionSetupPhase
    @State private var isExpanded: Bool
    @State private var hasAutoExpandedFailure: Bool
    @State private var logContentHeight: CGFloat = 0

    init(phase: SessionSetupPhase) {
        self.phase = phase
        // A phase that already failed when the view mounts (e.g. returning to
        // the session) starts expanded so the error is visible immediately.
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
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(theme.statusError)
                            .textSelection(.enabled)
                    }
                    if !phase.logs.isEmpty {
                        logLines
                    }
                }
                // Keep the header gap inside the measured reveal. If this is
                // outer VStack spacing, it survives at zero height until the
                // reveal settles, then disappears as a final 12pt jump.
                .padding(.top, 12)
            }
        }
        .onChange(of: phase.outcome) { _, outcome in
            switch outcome {
            case .failed:
                // Surface what went wrong without a click.
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
        // Keep the setup label stable while the shared disclosure primitives
        // animate only the chevron and the revealed content.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    /// "Setting up worktree… 12s" (shimmering, live timer) while running;
    /// "Set up worktree in 60s" once done; the failed title in warn color on
    /// error.
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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(phase.logs) { line in
                    Text(line.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.stream == "stderr" ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
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
    running.appendLog(stream: "stderr", line: "Preparing worktree (new branch 'herdman/fearless-raven')")
    running.appendLog(stream: "stdout", line: "git submodule update: cloning 12 repositories…")

    var done = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-64))
    done.succeed(durationMs: 60_000)

    var failed = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-3))
    failed.appendLog(stream: "stderr", line: "fatal: a branch named 'herdman/fix-auth' already exists")
    failed.fail(message: "fatal: a branch named 'herdman/fix-auth' already exists")

    // Ephemeral: shown only while running (removed on success, kept on failure).
    let agent = SessionSetupPhase.startingAgent(named: "Claude Code", startedAt: Date().addingTimeInterval(-2))

    return ScrollView {
        SessionSetupView(phases: [running, done, failed, agent])
            .padding()
    }
    .frame(width: 640, height: 420)
}
#endif
