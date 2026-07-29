import CodevisorCore
import CodevisorUI
import SwiftUI

/// The standalone new-chat page: a composer with project/run-location chips
/// (and the usual harness/config controls inside the card). NOTHING exists
/// until the first message is sent — sending resolves the picked directory
/// (project folder or a fresh worktree), creates the session, and hands the
/// live controller to the workspace screen the caller pushes.
struct NewChatScreen: View {
    @Environment(AppEnvironment.self) private var environment

    /// Called with the created session so the caller can navigate into it.
    let onStarted: (ChatSession) -> Void

    @State private var controller: SessionController?
    @State private var composerHeight: CGFloat = 0
    @State private var isAddingProject = false
    /// The first refresh hasn't answered yet: show a spinner, not the
    /// add-a-project empty state, while the project list may still arrive.
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if let controller {
                // The same hunk watermark a fresh chat shows before its first
                // message, centered in the space above the composer.
                Image("hunk")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 130)
                    .foregroundStyle(Color.primary.opacity(0.08))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                .safeAreaInset(edge: .bottom) {
                    ComposerBar(
                        controller: controller,
                        maxHeight: 420,
                        collapsedHeight: $composerHeight,
                        showsRunPickers: true
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            } else if !hasLoaded {
                ProgressView()
            } else {
                // A machine with no projects can't start a chat yet: offer
                // the folder browser right here.
                ContentUnavailableView {
                    Label("Add a Project First", systemImage: "folder.badge.plus")
                } description: {
                    Text("Chats work inside a project on \(environment.machines.selectedMachine.name).")
                } actions: {
                    Button {
                        isAddingProject = true
                    } label: {
                        Label("Add Project", systemImage: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingProject) {
            AddProjectSheet { _ in
                // The fresh project becomes the first active one; the
                // controller setup below picks it up.
                setUpControllerIfNeeded()
            }
        }
        .task {
            await environment.projectList.refreshFromServer()
            hasLoaded = true
            setUpControllerIfNeeded()
        }
        .onChange(of: environment.projectList.activeProjects.map(\.id)) { _, _ in
            setUpControllerIfNeeded()
        }
    }

    private func setUpControllerIfNeeded() {
        guard controller == nil,
              let project = environment.projectList.activeProjects.first(where: { !$0.isScratch })
        else { return }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.serverClient
        )
        controller.applyComposerDefaults()
        // Start from the machine's remembered run-location choice (the
        // refresh above already probed git-ness).
        controller.wantsNewWorktree = project.isGitRepository
            && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
                forServer: project.serverId
            )
        controller.onFirstSend = { [weak controller] in
            guard let controller else { return }
            let chatProject = controller.project
            let session = environment.projectList.newSession(
                in: chatProject,
                title: Self.title(from: controller.composerText),
                harnessId: controller.selectedHarnessId,
                worktreeName: controller.worktreeName,
                cwd: controller.sessionCwdOverride,
                syncToServer: false
            )
            controller.serverSession = session
            controller.onWorktreeCreated = { [weak projectList = environment.projectList] worktree in
                projectList?.setWorktree(
                    name: worktree.name,
                    cwd: worktree.path,
                    for: session.id,
                    serverId: session.serverId
                )
            }
            controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
                projectList?.setAgentSessionId(
                    agentSessionId,
                    for: session.id,
                    serverId: session.serverId
                )
            }
            ChatControllerCache.shared.register(
                controller,
                for: session,
                projectList: environment.projectList
            )
            onStarted(session)
        }
        self.controller = controller
        Task { await controller.prepare() }
    }

    private static func title(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "New session"
        return firstLine.count > 48
            ? String(firstLine.prefix(48)) + "…"
            : (firstLine.isEmpty ? "New session" : firstLine)
    }
}
