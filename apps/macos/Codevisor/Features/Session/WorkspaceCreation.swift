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

    var body: some View {
        Group {
            if creation.phases.isEmpty {
                Color.clear
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        SessionSetupView(phases: creation.phases)
                        if creation.hasFailure {
                            Button("Try Again") { Task { await run() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
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
