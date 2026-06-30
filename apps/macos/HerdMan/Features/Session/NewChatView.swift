import SwiftUI
import HerdManCore

/// The new-chat page: a centered "What should we build in <project>?" title with
/// an inline project dropdown, and the composer. The session is created only
/// when the user sends.
struct NewChatView: View {
    @Environment(AppEnvironment.self) private var environment
    let store: SessionStore
    @Binding var selection: SidebarSelection?
    var preferredWorkspaceId: UUID?

    @State private var controller: SessionController?
    @State private var selectedWorkspaceId: UUID?

    private var workspaces: [Workspace] { environment.workspaceList.activeWorkspaces }
    private var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceId } ?? workspaces.first
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 22) {
                title
                if let controller {
                    ComposerCard(controller: controller, placeholder: "Do anything")
                        .frame(maxWidth: 720)
                    statusLabel(controller)
                }
            }
            .frame(maxWidth: 720)
            .padding()
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("New Chat")
        .task(id: preferredWorkspaceId) { setUpController() }
    }

    // MARK: - Title with project dropdown

    @ViewBuilder
    private var title: some View {
        if workspaces.isEmpty {
            VStack(spacing: 10) {
                Text("Add a workspace to start")
                    .font(.system(size: 26, weight: .semibold))
                Text("Use the + next to Projects in the sidebar.")
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
            ForEach(workspaces) { workspace in
                Button {
                    selectedWorkspaceId = workspace.id
                    if let controller { Task { await controller.selectWorkspace(workspace) } }
                } label: {
                    if workspace.id == selectedWorkspace?.id {
                        Label(workspace.name, systemImage: "checkmark")
                    } else {
                        Text(workspace.name)
                    }
                }
            }
        } label: {
            Text(selectedWorkspace?.name ?? "project")
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

    @ViewBuilder
    private func statusLabel(_ controller: SessionController) -> some View {
        if case let .failed(message) = controller.status {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Setup

    private func setUpController() {
        selectedWorkspaceId = preferredWorkspaceId ?? workspaces.first?.id
        guard let workspace = selectedWorkspace else { return }
        let controller = store.makeDraft(workspace: workspace)
        controller.onFirstSend = { [weak controller] in
            guard let controller, let workspace = selectedWorkspace else { return }
            let title = Self.title(from: controller.composerText)
            let session = environment.workspaceList.newSession(
                in: workspace,
                title: title,
                harnessId: controller.selectedHarnessId
            )
            controller.serverSession = session
            // The eager connection may already hold an agent session id; persist
            // it, and capture any future-created id too.
            if let agentSessionId = controller.connectedAgentSessionId {
                environment.workspaceList.setAgentSessionId(agentSessionId, for: session.id)
            }
            controller.onAgentSessionCreated = { [weak workspaceList = environment.workspaceList] agentSessionId in
                workspaceList?.setAgentSessionId(agentSessionId, for: session.id)
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
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "New Session"
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : (firstLine.isEmpty ? "New Session" : firstLine)
    }
}

#Preview {
    @Previewable @State var selection: SidebarSelection?
    let environment = AppEnvironment.preview()
    return NewChatView(
        store: SessionStore(
            agentService: environment.agentService,
            configCache: environment.configCache,
            workspaceList: environment.workspaceList
        ),
        selection: $selection,
        preferredWorkspaceId: nil
    )
    .environment(environment)
    .frame(width: 900, height: 640)
}
