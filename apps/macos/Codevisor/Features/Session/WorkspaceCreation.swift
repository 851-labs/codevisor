import SwiftUI
import os
import CodevisorCore

/// Drives workspace creation, including materializing the worktree BEFORE
/// the workspace exists when "New worktree" is on — the worktree becomes the
/// workspace root, so every terminal and chat opens inside it from the first
/// frame. Progress and failures render through the same setup-phase card the
/// chat uses for its worktree log (`SessionSetupView`).
@MainActor
@Observable
final class WorkspaceCreationModel {
    private(set) var phases: [SessionSetupPhase] = []
    private(set) var isCreating = false

    /// Whether the last attempt ended in a failed phase (the card stays up
    /// with the error + captured logs; the caller offers a retry).
    var hasFailure: Bool {
        phases.contains { $0.failureMessage != nil }
    }

    /// Clears a failed attempt so the caller can return to its form.
    func reset() {
        guard !isCreating else { return }
        phases = []
    }

    /// Creates the workspace (worktree first when requested) and returns its
    /// eager chat session, or nil when worktree creation failed — the failed
    /// phase carries the message and logs.
    func create(
        project: Project,
        name: String,
        startingTab: WorkspaceStartingTab,
        newWorktree: Bool,
        store: SessionStore,
        environment: AppEnvironment
    ) async -> ChatSession? {
        guard !isCreating else { return nil }
        isCreating = true
        defer { isCreating = false }
        phases = []
        var worktree: ServerWorktree?
        if newWorktree {
            guard let created = await createWorktree(
                project: project,
                slug: WorkspaceNameGenerator.slug(from: name),
                client: environment.machines.client(for: project.serverId)
            ) else { return nil }
            worktree = created
        }
        return store.createWorkspaceSession(
            in: project,
            name: name,
            startingTab: startingTab,
            worktree: worktree
        )
    }

    /// Mirrors `SessionController.createWorktree`: a client-generated
    /// worktree id lets the server's `worktree.setup` events (git output,
    /// checkout hooks, failures) stream into the phase card while the HTTP
    /// request is in flight. Terminal state comes from the response.
    private func createWorktree(
        project: Project,
        slug: String,
        client: any CodevisorServerClienting
    ) async -> ServerWorktree? {
        let worktreeId = UUID().uuidString.lowercased()
        phases = [.worktree()]
        let follow = Task { [weak self] in
            do {
                for try await envelope in client.eventStream(
                    since: ServerSessionTransport.liveOnlyEventCursor
                ) {
                    guard case let .log(stream, line) = WorktreeSetupEvent.from(
                        envelope, worktreeId: worktreeId
                    ) else { continue }
                    self?.mutateWorktreePhase { $0.appendLog(stream: stream, line: line) }
                }
            } catch {
                // The stream is cosmetic; a drop just stops the live tail.
                Log.session.debug("workspace worktree log tail dropped: \(String(describing: error), privacy: .public)")
            }
        }
        defer { follow.cancel() }
        do {
            let worktree = try await client.createWorktree(
                projectId: project.id,
                id: worktreeId,
                name: slug
            )
            mutateWorktreePhase { $0.succeed() }
            return worktree
        } catch let CodevisorServerClientError.httpStatus(_, message) {
            mutateWorktreePhase { $0.fail(message: Self.failureMessage(from: message)) }
            return nil
        } catch {
            mutateWorktreePhase { $0.fail(message: serverErrorMessage(error)) }
            return nil
        }
    }

    private func mutateWorktreePhase(_ transform: (inout SessionSetupPhase) -> Void) {
        guard let index = phases.firstIndex(where: {
            $0.id == SessionSetupPhase.worktreePhaseId
        }) else { return }
        transform(&phases[index])
    }

    private static func failureMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              let error = payload["error"] else {
            return body.isEmpty ? "Could not create the worktree." : body
        }
        return error
    }
}

/// The New workspace page's worktree progress: a terminal-styled tail, NOT
/// the chat transcript's setup card (`SessionSetupView` stays as-is for
/// first-send worktrees in chat history). While running it shows the last
/// few streamed git/hook lines with a faded top edge, like a `tail -f`;
/// on failure it expands to the full log with the error pinned.
struct WorktreeCreationTail: View {
    let phase: SessionSetupPhase
    /// The worktree's name (the workspace's slug), for the status row.
    let worktreeName: String

    /// Lines visible while running — enough to feel alive without the card
    /// growing into a wall of git output.
    private static let runningTailCount = 6

    private var isFailed: Bool { phase.failureMessage != nil }

    /// A GitError's message is git's ENTIRE collected stderr — narration
    /// ("Preparing worktree …") included. Pin only the actual error line
    /// (the last `fatal:`/`error:` line, else the last line); the rest
    /// reads as log output.
    private var failureBlobLines: [String] {
        (phase.failureMessage ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var pinnedErrorLine: String? {
        guard isFailed else { return nil }
        let lines = failureBlobLines
        return lines.last { line in
            line.hasPrefix("fatal:") || line.hasPrefix("error:")
        } ?? lines.last ?? phase.failureMessage
    }

    /// The lines shown in the log area: the streamed tail when the socket
    /// delivered any; otherwise (fast failures beat the socket attach) the
    /// failure blob's narration lines stand in.
    private var displayLogs: [SessionSetupLogLine] {
        if !phase.logs.isEmpty { return phase.logs }
        guard isFailed else { return [] }
        let pinned = pinnedErrorLine
        return failureBlobLines
            .filter { $0 != pinned }
            .enumerated()
            .map { SessionSetupLogLine(id: $0.offset, stream: "stderr", text: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if !displayLogs.isEmpty {
                logView
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            if let message = pinnedErrorLine {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        // A terminal is dark in both appearances — that's the point of the
        // styling. Not themed: this surface imitates a shell, not the app.
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            switch phase.outcome {
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Creating worktree \(worktreeName)…")
                    .foregroundStyle(.white.opacity(0.85))
                    .shimmering()
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Created worktree \(worktreeName)")
                    .foregroundStyle(.white.opacity(0.85))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Could not create worktree \(worktreeName)")
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .font(.callout.weight(.medium))
    }

    /// Running: the last few lines, top edge faded (a live tail). Failed:
    /// the whole log, scrollable, so the git error is inspectable.
    @ViewBuilder
    private var logView: some View {
        if isFailed {
            ScrollViewReader { proxy in
                ScrollView {
                    logLines(displayLogs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .onAppear { proxy.scrollTo(bottomAnchorId, anchor: .bottom) }
            }
        } else {
            logLines(Array(displayLogs.suffix(Self.runningTailCount)))
                .frame(maxWidth: .infinity, alignment: .leading)
                // Older lines dissolve upward as new ones stream in.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.35),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .animation(.easeOut(duration: 0.15), value: phase.logs.count)
        }
    }

    private var bottomAnchorId: Int { displayLogs.last?.id ?? 0 }

    private func logLines(_ lines: [SessionSetupLogLine]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(
                        line.stream == "stderr"
                            ? Color.white.opacity(0.55)
                            : Color.white.opacity(0.7)
                    )
                    .lineLimit(isFailed ? nil : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .id(line.id)
            }
        }
    }
}

/// The one-click "New workspace here" path: creates immediately with the
/// remembered settings (mode + worktree) and a generated name. Blank until
/// a worktree setup starts; then the same live log card as the form page,
/// with a retry on failure.
struct QuickWorkspaceCreationView: View {
    @Environment(AppEnvironment.self) private var environment
    let project: Project
    let store: SessionStore
    @Binding var selection: SidebarSelection?

    @State private var creation = WorkspaceCreationModel()
    @State private var pendingName = ""

    var body: some View {
        Group {
            if let phase = creation.phases.first {
                ScrollView {
                    VStack(spacing: 16) {
                        WorktreeCreationTail(
                            phase: phase,
                            worktreeName: WorkspaceNameGenerator.slug(from: pendingName)
                        )
                        if creation.hasFailure {
                            Button("Try Again") { Task { await run() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: 480)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Color.clear
            }
        }
        .task(id: project.id) { await run() }
    }

    private func run() async {
        // Only auto-start on a fresh view: a visible failure must not retry
        // on its own when the task(id:) re-fires — only the button does.
        guard !creation.isCreating, creation.phases.isEmpty else { return }
        await start()
    }

    private func start() async {
        let remembered = environment.newWorkspaceDefaults.defaults(forServer: project.serverId)
        let startingTab = remembered?.startingTab.flatMap(WorkspaceStartingTab.init(rawValue:)) ?? .chat
        let newWorktree = (remembered?.newWorktree ?? false) && project.isGitRepository
        let taken = Set(environment.workspaces.loadAll().map { $0.name.lowercased() })
        let name = WorkspaceNameGenerator.next(excluding: taken)
        pendingName = name
        guard let session = await creation.create(
            project: project,
            name: name,
            startingTab: startingTab,
            newWorktree: newWorktree,
            store: store,
            environment: environment
        ) else { return }
        environment.newWorkspaceDefaults.remember(
            NewWorkspaceDefaultsStore.Defaults(
                projectId: project.id,
                startingTab: startingTab.rawValue,
                newWorktree: newWorktree
            ),
            forServer: project.serverId
        )
        selection = .session(serverId: session.serverId, id: session.id)
    }
}
