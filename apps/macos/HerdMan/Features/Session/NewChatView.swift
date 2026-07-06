import SwiftUI
import HerdManCore

/// The new-chat page: a centered "What should we build in <project>?" title with
/// an inline project dropdown, and the composer. The session is created only
/// when the user sends.
struct NewChatView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    let store: SessionStore
    @Binding var selection: SidebarSelection?
    var preferredProjectId: UUID?
    /// Set when the page was opened for a specific project (sidebar "+" /
    /// "New chat here"); nil for the generic new-chat entry. An explicit
    /// project moves a retained draft; an implicit one follows the draft.
    var explicitProjectId: UUID?

    @State private var controller: SessionController?
    @State private var selectedProjectId: UUID?
    @State private var runInWorktree = false
    @State private var focus = TerminalFocusController()

    private var projects: [Project] { environment.projectList.activeProjects }
    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }

    /// Worktrees only make sense when the project folder is a git repository
    /// (as probed by the session's server).
    private var worktreeAvailable: Bool {
        selectedProject?.isGitRepository ?? false
    }

    var body: some View {
        VStack {
            // 2:3 spacer split sits the composer slightly above true center.
            Spacer()
            Spacer()
            VStack(spacing: 22) {
                title
                if let controller {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(spacing: 0) {
                            ComposerCard(
                                controller: controller,
                                placeholder: "Do anything",
                                showsHarnessPicker: false,
                                onTextViewReady: { textView in
                                    focus.composerTextView = textView
                                    // The text view isn't attached to a window yet during
                                    // makeNSView; focus once it is.
                                    DispatchQueue.main.async { focus.focusComposer() }
                                }
                            )
                            .zIndex(1)
                            // The accessory strip: tucked under the card's
                            // rounded bottom so the two read as one control.
                            HStack(spacing: 14) {
                                HarnessPickerMenu(controller: controller)
                                runLocationPicker(controller)
                            }
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.top, 16 + 9)
                            .padding(.bottom, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                UnevenRoundedRectangle(
                                    bottomLeadingRadius: 16,
                                    bottomTrailingRadius: 16,
                                    style: .continuous
                                )
                                .fill(theme.cardQuietBackground)
                            )
                            .padding(.top, -16)
                        }
                        statusLabel(controller)
                    }
                    .frame(maxWidth: 720)
                }
            }
            .frame(maxWidth: 720)
            .padding()
            Spacer()
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .attachmentDropTarget(controller)
        .navigationTitle("New chat")
        .task(id: preferredProjectId) { setUpController() }
        .focusedSceneValue(\.newChatComposerFocus, NewChatComposerFocus(
            focus: { focus.focusComposer() }
        ))
    }

    // MARK: - Title with project dropdown

    @ViewBuilder
    private var title: some View {
        if projects.isEmpty {
            VStack(spacing: 10) {
                Text("Add a project to start")
                    .font(.system(size: 26, weight: .semibold))
                Text("Use the + next to projects in the sidebar.")
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 0) {
                Text("What should we build in ")
                projectMenu
                Text("?")
            }
            .font(.system(size: 26, weight: .semibold))
            .multilineTextAlignment(.center)
        }
    }

    private var projectMenu: some View {
        Menu {
            ForEach(projects) { project in
                Button {
                    selectedProjectId = project.id
                    // Worktree choice doesn't carry across projects that can't support it.
                    if !(project.isGitRepository) {
                        runInWorktree = false
                        controller?.wantsNewWorktree = false
                    }
                    if let controller { Task { await controller.selectProject(project) } }
                } label: {
                    if project.id == selectedProject?.id {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
        } label: {
            Text(selectedProject?.name ?? "project")
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// "Project directory" vs "New worktree" for where the chat runs. Worktree
    /// is only offered for git projects; the worktree itself is created on the
    /// first send.
    @ViewBuilder
    private func runLocationPicker(_ controller: SessionController) -> some View {
        Menu {
            Toggle(isOn: Binding(
                get: { !runInWorktree },
                set: { isOn in
                    guard isOn, runInWorktree else { return }
                    runInWorktree = false
                    controller.wantsNewWorktree = false
                    // Re-establish the eager connection in the project folder.
                    Task { await controller.reconnect() }
                }
            )) {
                Label {
                    Text("Project directory")
                } icon: {
                    MenuSymbolIcon(systemName: "folder.fill")
                }
            }
            Toggle(isOn: Binding(
                get: { runInWorktree },
                set: { isOn in
                    guard isOn, !runInWorktree else { return }
                    runInWorktree = true
                    controller.wantsNewWorktree = true
                    // Drop any eager connection pinned to the project folder; the
                    // agent reconnects in the worktree on first send.
                    Task { await controller.reconnect() }
                }
            )) {
                Label {
                    Text("New worktree")
                } icon: {
                    MenuSymbolIcon(systemName: "arrow.triangle.branch")
                }
            }
            .disabled(!worktreeAvailable)
        } label: {
            PickerChip(text: runInWorktree ? "New worktree" : "Project directory") {
                Image(systemName: runInWorktree ? "arrow.triangle.branch" : "folder.fill")
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            worktreeAvailable
                ? "Where this chat's commands run"
                : "Worktrees need the project folder to be a git repository"
        )
    }

    @ViewBuilder
    private func statusLabel(_ controller: SessionController) -> some View {
        if case let .failed(message) = controller.status {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(theme.statusWarn)
        }
    }

    // MARK: - Setup

    private func setUpController() {
        selectedProjectId = preferredProjectId ?? projects.first?.id
        guard let project = selectedProject else { return }
        let controller = store.draft(project: project)
        if controller.project.id != project.id {
            let draftProjectExists = projects.contains { $0.id == controller.project.id }
            if explicitProjectId == project.id || !draftProjectExists {
                // Opened explicitly for this project (or the draft's project is
                // gone): move the draft here, keeping its text/attachments.
                Task { await controller.selectProject(project) }
            } else {
                // Generic entry: follow the draft's own project so the title
                // and pickers match the composer state the user left.
                selectedProjectId = controller.project.id
            }
        }
        // Restore the draft's worktree choice (remembered defaults or an
        // earlier visit), clamped to projects that can support it.
        if !worktreeAvailable { controller.wantsNewWorktree = false }
        runInWorktree = controller.wantsNewWorktree
        controller.onFirstSend = { [weak controller] in
            guard let controller, let project = selectedProject else { return }
            let title = Self.title(from: controller.composerText)
            let session = environment.projectList.newSession(
                in: project,
                title: title,
                harnessId: controller.selectedHarnessId,
                worktreeName: controller.worktreeName,
                cwd: controller.sessionCwdOverride,
                syncToServer: false
            )
            controller.serverSession = session
            // The eager connection may already hold an agent session id; persist
            // it, and capture any future-created id too.
            if let agentSessionId = controller.connectedAgentSessionId {
                environment.projectList.setAgentSessionId(agentSessionId, for: session.id)
            }
            controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
                projectList?.setAgentSessionId(agentSessionId, for: session.id)
            }
            // The session record is registered before the worktree exists (the
            // page opens while setup streams progress); patch in the worktree
            // name/cwd once the server has materialized it.
            controller.onWorktreeCreated = { [weak projectList = environment.projectList] worktree in
                projectList?.setWorktree(name: worktree.name, cwd: worktree.path, for: session.id)
            }
            // If worktree setup or the agent start fails, undo the promotion:
            // delete the just-created session record (local + server), demote
            // the controller back to the draft slot, and reopen the new-chat
            // page — its status label shows the failure.
            controller.onSetupFailed = { [weak controller, weak projectList = environment.projectList] in
                guard let controller else { return }
                projectList?.deleteSession(session)
                controller.serverSession = nil
                controller.onAgentSessionCreated = nil
                controller.onWorktreeCreated = nil
                store.demote(controller, sessionId: session.id)
                selection = .newChat(project.id)
            }
            store.register(controller, for: session.id)
            selection = .session(session.id)
        }
        self.controller = controller
        Task {
            await controller.prepare()
            if !AppPreview.isRunning { await controller.connectIfNeeded() }
        }
    }

    private static func title(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "New session"
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : (firstLine.isEmpty ? "New session" : firstLine)
    }
}

#Preview {
    @Previewable @State var selection: SidebarSelection?
    let environment = AppEnvironment.preview()
    return NewChatView(
        store: SessionStore(environment: environment),
        selection: $selection,
        preferredProjectId: nil
    )
    .environment(environment)
    .frame(width: 900, height: 640)
}
