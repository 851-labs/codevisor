import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Pane persistence

/// Client-side persistence of each workspace's panes, reusing the shared
/// `PaneGroupState`/`PaneDescriptorState` model — including the
/// `"<sessionUuid>:<paneUuid>"` terminal-key scheme, so pane PTYs are keyed
/// identically to macOS. Returning to a workspace restores the same panes
/// with the same pane selected.
@MainActor
@Observable
final class WorkspacePaneStore {
    static let shared = WorkspacePaneStore()

    private var cache: [UUID: PaneGroupState] = [:]

    private func key(for sessionId: UUID) -> String {
        "ios.workspace.panes.\(sessionId.uuidString)"
    }

    func state(for sessionId: UUID) -> PaneGroupState {
        if let cached = cache[sessionId] { return cached }
        if let data = UserDefaults.standard.data(forKey: key(for: sessionId)),
           let decoded = try? JSONDecoder().decode(PaneGroupState.self, from: data) {
            cache[sessionId] = decoded
            return decoded
        }
        let initial = PaneGroupState.centerInitial(sessionId: sessionId)
        cache[sessionId] = initial
        return initial
    }

    func save(_ state: PaneGroupState, for sessionId: UUID) {
        cache[sessionId] = state
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key(for: sessionId))
        }
    }
}

/// Safari-style pane previews: the visible pane is snapshotted when the grid
/// opens (and when switching away), so the grid shows real content for panes
/// you've visited. In-memory only — placeholders return after relaunch until
/// a pane is shown again.
@MainActor
final class PaneSnapshotCache {
    static let shared = PaneSnapshotCache()
    var images: [UUID: UIImage] = [:]

    func captureKeyWindow(for paneId: UUID) {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.keyWindow
        else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        images[paneId] = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

// MARK: - Workspace screen

/// A workspace: one full-screen pane at a time (chat, terminals), with a
/// Safari-style grid to switch, add, and close panes. The nav bar shows the
/// active pane's title between a sidebar button (back to the workspace list)
/// and the pane-grid button.
struct WorkspaceScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID

    @State private var controller: SessionController?
    @State private var missing = false
    @State private var serverConfig: CodevisorServerConfig?
    @State private var paneState: PaneGroupState?
    @State private var showsGrid = false

    private var panes: PaneGroupState {
        paneState ?? WorkspacePaneStore.shared.state(for: sessionId)
    }

    private var activePane: PaneDescriptorState? {
        panes.selectedPane ?? panes.panes.first
    }

    private var session: ChatSession? {
        environment.projectList.sessions.first { $0.id == sessionId }
    }

    private var activePaneTitle: String {
        guard let pane = activePane else { return "Workspace" }
        if pane.kind == .chat {
            let title = session?.title ?? pane.name
            return title.isEmpty ? "New Chat" : title
        }
        return pane.name
    }

    private var workspaceCwd: String {
        session?.cwd
            ?? controller?.project.folderURL.path
            ?? ""
    }

    var body: some View {
        Group {
            if let controller, let pane = activePane {
                paneContent(pane, controller: controller)
                    .id(pane.id)
            } else if missing {
                ContentUnavailableView("Chat Not Found", systemImage: "questionmark.bubble")
            } else {
                ProgressView()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(activePaneTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel("Workspaces")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openGrid()
                } label: {
                    Image(systemName: "square.on.square")
                }
                .accessibilityLabel("Show panes")
            }
        }
        .fullScreenCover(isPresented: $showsGrid) {
            PaneGridView(
                sessionId: sessionId,
                sessionTitle: session?.title ?? "Chat",
                cwd: workspaceCwd,
                paneState: Binding(
                    get: { panes },
                    set: { newValue in
                        paneState = newValue
                        WorkspacePaneStore.shared.save(newValue, for: sessionId)
                    }
                )
            )
        }
        .task { await prepare() }
    }

    @ViewBuilder
    private func paneContent(_ pane: PaneDescriptorState, controller: SessionController) -> some View {
        switch pane.kind {
        case .chat, .newTab:
            SessionTranscriptView(controller: controller, serverConfig: serverConfig)
        case .terminal:
            if let serverConfig {
                TerminalPaneView(
                    terminalKey: pane.terminalKey,
                    cwd: pane.cwdOverride ?? workspaceCwd,
                    config: serverConfig
                )
            } else {
                ContentUnavailableView("No Machine", systemImage: "bolt.slash")
            }
        }
    }

    private func openGrid() {
        if let pane = activePane {
            PaneSnapshotCache.shared.captureKeyWindow(for: pane.id)
        }
        showsGrid = true
    }

    private func prepare() async {
        if paneState == nil {
            paneState = WorkspacePaneStore.shared.state(for: sessionId)
        }
        guard controller == nil else { return }
        guard let session = environment.projectList.sessions.first(where: { $0.id == sessionId }),
              let project = environment.projectList.projects.first(where: { $0.id == session.projectId })
        else {
            missing = true
            return
        }
        serverConfig = environment.machines.machine(for: session.serverId)?.serverConfig
            ?? environment.machines.selectedMachine.serverConfig
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.machines.client(for: session.serverId)
        )
        controller.configureExistingSession(session)
        self.controller = controller
        if session.agentSessionId?.isEmpty != false {
            // A fresh chat: no agent exists yet. Load harness capabilities so
            // the composer validates; the agent spawns on the first send.
            await controller.prepare()
            controller.applyComposerDefaults()
        }
        await controller.connectIfNeeded()
    }
}

// MARK: - Pane grid

/// The Safari-style pane switcher: a two-column grid of pane previews with
/// close buttons, plus a bottom bar to add a terminal and dismiss.
private struct PaneGridView: View {
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID
    let sessionTitle: String
    let cwd: String
    @Binding var paneState: PaneGroupState

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(paneState.panes) { pane in
                        PaneCard(
                            pane: pane,
                            title: title(for: pane),
                            isActive: pane.id == paneState.selectedPaneId,
                            canClose: closablePane(pane),
                            onSelect: { select(pane) },
                            onClose: { close(pane) }
                        )
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(paneState.panes.count) Pane\(paneState.panes.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            addTerminal()
                        } label: {
                            Label("New Terminal", systemImage: "terminal")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add pane")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func title(for pane: PaneDescriptorState) -> String {
        pane.kind == .chat ? (sessionTitle.isEmpty ? "New Chat" : sessionTitle) : pane.name
    }

    /// The workspace's chat pane is its anchor — it can't be closed here
    /// (archiving a chat is a workspace-list action, as on macOS).
    private func closablePane(_ pane: PaneDescriptorState) -> Bool {
        pane.kind != .chat
    }

    private func select(_ pane: PaneDescriptorState) {
        var state = paneState
        state.selectedPaneId = pane.id
        paneState = state
        dismiss()
    }

    private func close(_ pane: PaneDescriptorState) {
        var state = paneState
        state.panes.removeAll { $0.id == pane.id }
        if state.selectedPaneId == pane.id {
            state.selectedPaneId = state.panes.first?.id
        }
        paneState = state
        PaneSnapshotCache.shared.images[pane.id] = nil
    }

    private func addTerminal() {
        var state = paneState
        state.addTerminalPane(sessionId: sessionId, cwdOverride: cwd)
        paneState = state
        dismiss()
    }
}

/// One preview card: the pane's last snapshot when we have one, otherwise an
/// icon placeholder; title chip underneath; ✕ to close.
private struct PaneCard: View {
    let pane: PaneDescriptorState
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var snapshot: UIImage? {
        PaneSnapshotCache.shared.images[pane.id]
    }

    private var symbolName: String {
        pane.kind == .terminal ? "terminal" : "bubble.left.and.bubble.right"
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(pane.kind == .terminal ? Color.black : Color(.secondarySystemGroupedBackground))
                if let snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(pane.kind == .terminal ? Color.white.opacity(0.6) : Color.secondary)
                }
            }
            .aspectRatio(0.62, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        isActive ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isActive ? 2.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                    .accessibilityLabel("Close \(title)")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture { onSelect() }

            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) pane")
        .accessibilityAddTraits(.isButton)
    }
}
