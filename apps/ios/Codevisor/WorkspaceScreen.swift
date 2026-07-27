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

/// Safari-style tab previews: the visible pane is snapshotted (with the app's
/// own navigation chrome cropped off) when the grid opens, so the grid shows
/// real content for panes you've visited. In-memory only — placeholders
/// return after relaunch until a pane is shown again.
@MainActor
final class PaneSnapshotCache {
    static let shared = PaneSnapshotCache()
    var images: [UUID: UIImage] = [:]
    /// The visible chat pane's composer-stack height, written by the pane
    /// body so captures can crop it. (Plain storage, not a SwiftUI
    /// preference: preferences fed back into navigation state cancel
    /// in-flight push transitions.)
    var activeBottomChrome: CGFloat = 0

    /// `bottomChrome` is the height of pane-owned chrome above the safe area
    /// (the chat composer) to exclude, so previews show only content.
    func captureKeyWindow(for paneId: UUID, bottomChrome: CGFloat = 0) {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.keyWindow
        else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let full = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        // Crop the status/nav band and any bottom chrome so the preview
        // shows only the pane's content, like Safari's tab pictures.
        let topChrome = window.safeAreaInsets.top + 44
        let bottomCrop = bottomChrome > 0 ? bottomChrome + window.safeAreaInsets.bottom : 0
        let scale = full.scale
        let cropRect = CGRect(
            x: 0,
            y: topChrome * scale,
            width: full.size.width * scale,
            height: max(1, (full.size.height - topChrome - bottomCrop)) * scale
        )
        if let cgImage = full.cgImage?.cropping(to: cropRect) {
            images[paneId] = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        } else {
            images[paneId] = full
        }
    }
}

// MARK: - Workspace screen

/// A workspace: one full-screen pane (tab) at a time — chats, terminals, and
/// the new-tab page — with a Safari-style grid to switch, add, and close
/// them. The nav bar shows the active pane's title between a sidebar button
/// (back to the workspace list) and the tab-grid button; chat panes hide
/// their title so the transcript scrolls clear off the top.
struct WorkspaceScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID

    /// One controller per chat session shown in this workspace (macOS allows
    /// several chats per workspace; so do we).
    @State private var controllers: [UUID: SessionController] = [:]
    @State private var missing = false
    @State private var serverConfig: CodevisorServerConfig?
    @State private var project: Project?
    @State private var paneState: PaneGroupState?
    /// The active pane presents over the grid; the system zoom transition
    /// grows it out of its card (and shrinks it back), exactly like Photos
    /// and the App Store — no hand-rolled motion.
    @State private var showsPane = false
    /// Entering from the workspaces list is plain navigation: the pane
    /// renders inline so the push is the standard slide. The grid becomes
    /// the base (and the pane a zoom cover) only once tabs are opened.
    @State private var baseShowsGrid = false
    @Namespace private var paneZoom

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var panes: PaneGroupState {
        paneState ?? WorkspacePaneStore.shared.state(for: sessionId)
    }

    private var activePane: PaneDescriptorState? {
        panes.selectedPane ?? panes.panes.first
    }

    private func session(for id: UUID) -> ChatSession? {
        environment.projectList.sessions.first { $0.id == id }
    }

    private var rootSession: ChatSession? { session(for: sessionId) }

    private func title(for pane: PaneDescriptorState) -> String {
        switch pane.kind {
        case .chat:
            let title = session(for: pane.chatSessionId ?? sessionId)?.title ?? pane.name
            return title.isEmpty ? "New Chat" : title
        case .newTab:
            return "New Tab"
        case .terminal:
            return pane.name
        }
    }

    private var workspaceCwd: String {
        rootSession?.cwd
            ?? project?.folderURL.path
            ?? ""
    }

    var body: some View {
        Group {
            if missing {
                ContentUnavailableView("Chat Not Found", systemImage: "questionmark.bubble")
            } else if project == nil {
                ProgressView()
            } else if baseShowsGrid {
                grid
            } else if let pane = activePane {
                // Entry mode: the pane inline, riding the normal push slide.
                paneContent(pane)
                    .id(pane.id)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(baseTitle)
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
                if baseShowsGrid {
                    Button {
                        addTab()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New tab")
                } else {
                    Button {
                        if let pane = activePane { showGridFromInline(pane) }
                    } label: {
                        Image(systemName: "square.on.square")
                    }
                    .accessibilityLabel("Show tabs")
                }
            }
        }
        .fullScreenCover(isPresented: $showsPane) {
            paneCover
        }
        .task { await prepare() }
    }

    private var baseTitle: String {
        if baseShowsGrid {
            return "\(panes.panes.count) Tab\(panes.panes.count == 1 ? "" : "s")"
        }
        guard let pane = activePane else { return "" }
        // Chat panes hide the title so the transcript scrolls off the top.
        return pane.kind == .chat ? "" : title(for: pane)
    }

    // MARK: - Tab grid (the workspace's base)

    /// The Safari-style tab switcher: a two-column grid of pane previews with
    /// close buttons. Each card is the zoom transition's source, so opening a
    /// tab grows it out of its card.
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(panes.panes) { pane in
                    PaneCard(
                        pane: pane,
                        title: title(for: pane),
                        isActive: pane.id == panes.selectedPaneId,
                        onSelect: { select(pane) },
                        onClose: { close(pane) }
                    )
                    .matchedTransitionSource(id: pane.id, in: paneZoom)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// The presented pane: its own navigation bar (sidebar back, title,
    /// tab-grid button), zooming from the selected card. Chat panes hide the
    /// title so the transcript scrolls clear off the top.
    @ViewBuilder
    private var paneCover: some View {
        if let pane = activePane {
            NavigationStack {
                paneContent(pane)
                    .id(pane.id)
                    .navigationTitle(pane.kind == .chat ? "" : title(for: pane))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                leaveWorkspace()
                            } label: {
                                Image(systemName: "sidebar.left")
                            }
                            .accessibilityLabel("Workspaces")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showGrid(from: pane)
                            } label: {
                                Image(systemName: "square.on.square")
                            }
                            .accessibilityLabel("Show tabs")
                        }
                    }
            }
            .navigationTransition(.zoom(sourceID: pane.id, in: paneZoom))
        }
    }

    private var paneBinding: Binding<PaneGroupState> {
        Binding(
            get: { panes },
            set: { newValue in
                var state = newValue
                // macOS behavior: a group never goes empty — closing the last
                // pane leaves a New Tab page in its place.
                if state.panes.isEmpty {
                    state.addNewTabPane(inheritedCwd: workspaceCwd)
                }
                paneState = state
                WorkspacePaneStore.shared.save(state, for: sessionId)
            }
        )
    }

    @ViewBuilder
    private func paneContent(_ pane: PaneDescriptorState) -> some View {
        switch pane.kind {
        case .chat:
            let chatId = pane.chatSessionId ?? sessionId
            if let controller = controllers[chatId] {
                SessionTranscriptView(controller: controller, serverConfig: serverConfig)
                    // Attention: the visible chat is the open one — clear its
                    // unread state now and keep it clear as turns finish.
                    .onAppear {
                        guard let session = session(for: chatId) else { return }
                        ChatControllerCache.shared.noteOpened(
                            sessionId: chatId,
                            serverId: session.serverId,
                            projectList: environment.projectList
                        )
                    }
                    .onDisappear {
                        guard let session = session(for: chatId) else { return }
                        ChatControllerCache.shared.noteClosed(
                            sessionId: chatId,
                            serverId: session.serverId
                        )
                    }
            } else {
                ProgressView()
                    .task { await connectChat(sessionId: chatId) }
            }
        case .newTab:
            NewTabPaneView(
                projectName: project?.name ?? "",
                onNewChat: { convertToChat(pane) },
                onNewTerminal: { convertToTerminal(pane) }
            )
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

    // MARK: - Tab actions

    private func select(_ pane: PaneDescriptorState) {
        var state = panes
        state.selectedPaneId = pane.id
        paneBinding.wrappedValue = state
        showsPane = true
    }

    /// Any tab can close — chats included, as on macOS. The binding's setter
    /// backfills a New Tab page if the last one goes.
    private func close(_ pane: PaneDescriptorState) {
        var state = panes
        state.panes.removeAll { $0.id == pane.id }
        if state.selectedPaneId == pane.id {
            state.selectedPaneId = state.panes.first?.id
        }
        paneBinding.wrappedValue = state
        PaneSnapshotCache.shared.images[pane.id] = nil
    }

    /// Instant new tab, macOS-style: the page itself offers what the tab
    /// becomes. Presented on the next tick so its card exists as the zoom
    /// source.
    private func addTab() {
        var state = panes
        state.addNewTabPane(inheritedCwd: workspaceCwd)
        paneBinding.wrappedValue = state
        Task { @MainActor in
            showsPane = true
        }
    }

    /// Snapshot the pane for its card, then let the system zoom shrink the
    /// pane back into the grid.
    private func showGrid(from pane: PaneDescriptorState) {
        PaneSnapshotCache.shared.captureKeyWindow(
            for: pane.id,
            bottomChrome: pane.kind == .chat ? PaneSnapshotCache.shared.activeBottomChrome : 0
        )
        showsPane = false
    }

    /// First grid opening from the inline (entry) pane: swap the grid in
    /// underneath and re-host the pane as the zoom cover in one un-animated
    /// step — the screen doesn't change — then dismiss the cover so the
    /// system zoom shrinks the pane into its card.
    private func showGridFromInline(_ pane: PaneDescriptorState) {
        PaneSnapshotCache.shared.captureKeyWindow(
            for: pane.id,
            bottomChrome: pane.kind == .chat ? PaneSnapshotCache.shared.activeBottomChrome : 0
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            baseShowsGrid = true
            showsPane = true
        }
        Task { @MainActor in
            // Let the cover attach before asking it to animate away.
            try? await Task.sleep(for: .milliseconds(80))
            showsPane = false
        }
    }

    /// Back to the workspaces list: drop the pane cover without animation so
    /// the pop reads as one motion.
    private func leaveWorkspace() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsPane = false }
        dismiss()
    }

    /// The macOS new-tab conversion: the placeholder becomes a real pane in
    /// place. Chats are created eagerly as deferred sessions (the agent
    /// spawns on first send), exactly like the New Workspace flow.
    private func convertToChat(_ pane: PaneDescriptorState) {
        guard let project else { return }
        let chat = environment.projectList.newSession(in: project, title: "New Chat")
        var state = panes
        state.convertNewTabPane(id: pane.id, to: .chat, sessionId: sessionId, chatSessionId: chat.id)
        paneBinding.wrappedValue = state
    }

    private func convertToTerminal(_ pane: PaneDescriptorState) {
        var state = panes
        state.convertNewTabPane(
            id: pane.id,
            to: .terminal,
            sessionId: sessionId,
            cwd: pane.cwdOverride ?? workspaceCwd
        )
        paneBinding.wrappedValue = state
    }

    // MARK: - Connection

    private func prepare() async {
        if paneState == nil {
            paneState = WorkspacePaneStore.shared.state(for: sessionId)
        }
        if controllers[sessionId] == nil {
            guard let session = rootSession,
                  let project = environment.projectList.projects.first(where: { $0.id == session.projectId })
            else {
                missing = true
                return
            }
            self.project = project
            serverConfig = environment.machines.machine(for: session.serverId)?.serverConfig
                ?? environment.machines.selectedMachine.serverConfig
        }
        await connectChat(sessionId: sessionId)
    }

    private func connectChat(sessionId chatId: UUID) async {
        guard controllers[chatId] == nil,
              let session = session(for: chatId),
              let project = environment.projectList.projects.first(where: { $0.id == session.projectId })
        else { return }
        // App-wide cache: revisiting a chat rebinds the SAME controller, so a
        // stream that kept flowing while we were away renders immediately.
        let controller = ChatControllerCache.shared.controller(
            for: session,
            project: project,
            environment: environment
        )
        controllers[chatId] = controller
        guard controller.model == nil, !controller.isConnecting else { return }
        if session.agentSessionId?.isEmpty != false {
            // A fresh chat: no agent exists yet. Load harness capabilities so
            // the composer validates; the agent spawns on the first send.
            await controller.prepare()
            controller.applyComposerDefaults()
        }
        await controller.connectIfNeeded()
    }
}

// MARK: - New tab page

/// The iOS take on macOS's new-tab page: pick what this tab becomes. The
/// placeholder converts in place, so the tab keeps its slot in the grid.
private struct NewTabPaneView: View {
    let projectName: String
    let onNewChat: () -> Void
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            newTabOption(
                title: "New Chat",
                subtitle: "Start an agent in \(projectName)",
                systemImage: "bubble.left.and.bubble.right",
                action: onNewChat
            )
            newTabOption(
                title: "New Terminal",
                subtitle: "Open a shell on the machine",
                systemImage: "terminal",
                action: onNewTerminal
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func newTabOption(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 34)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// One preview card: the pane's last snapshot when we have one, otherwise an
/// icon placeholder; title chip underneath; ✕ to close.
private struct PaneCard: View {
    let pane: PaneDescriptorState
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var snapshot: UIImage? {
        PaneSnapshotCache.shared.images[pane.id]
    }

    private var symbolName: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .newTab: "plus.square.on.square"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(pane.kind == .terminal ? Color.black : Color(.secondarySystemGroupedBackground))
                if let snapshot {
                    // Top-aligned fill inside the fixed card, overflow clipped
                    // by the card shape.
                    Color.clear
                        .overlay(alignment: .top) {
                            Image(uiImage: snapshot)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                } else {
                    VStack {
                        Spacer()
                        Image(systemName: symbolName)
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(pane.kind == .terminal ? Color.white.opacity(0.6) : Color.secondary)
                        Spacer()
                    }
                }
            }
            // Fixed Safari-like height: every card matches regardless of
            // how tall its snapshot is.
            .frame(height: 205)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isActive ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isActive ? 2.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
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
            .contentShape(RoundedRectangle(cornerRadius: 16))
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
        .accessibilityLabel("\(title) tab")
        .accessibilityAddTraits(.isButton)
    }
}
