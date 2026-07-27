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
    @State private var showsGrid = false

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

    /// Chat panes ask for a hidden nav title so the transcript can scroll
    /// all the way off the top; other panes keep theirs.
    private var hidesTitle: Bool {
        activePane?.kind == .chat
    }

    private var workspaceCwd: String {
        rootSession?.cwd
            ?? project?.folderURL.path
            ?? ""
    }

    var body: some View {
        Group {
            if let pane = activePane, project != nil {
                paneContent(pane)
                    .id(pane.id)
            } else if missing {
                ContentUnavailableView("Chat Not Found", systemImage: "questionmark.bubble")
            } else {
                ProgressView()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(hidesTitle ? "" : (activePane.map(title(for:)) ?? "Workspace"))
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
                .accessibilityLabel("Show tabs")
            }
        }
        // A cover with the system slide disabled: the grid animates its own
        // Safari-style zoom (in from the active tab, out into the tapped
        // one). Structural transitions inside the pushed view itself corrupt
        // NavigationStack's transaction and pop the workspace.
        .fullScreenCover(isPresented: $showsGrid) {
            PaneGridView(
                titleFor: { title(for: $0) },
                cwd: workspaceCwd,
                paneState: paneBinding,
                onDismiss: { closeGrid() }
            )
            .presentationBackground(.clear)
        }
        .task { await prepare() }
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
            if let controller = controllers[pane.chatSessionId ?? sessionId] {
                SessionTranscriptView(controller: controller, serverConfig: serverConfig)
            } else {
                ProgressView()
                    .task { await connectChat(sessionId: pane.chatSessionId ?? sessionId) }
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

    private func openGrid() {
        if let pane = activePane {
            PaneSnapshotCache.shared.captureKeyWindow(
                for: pane.id,
                bottomChrome: pane.kind == .chat ? PaneSnapshotCache.shared.activeBottomChrome : 0
            )
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsGrid = true }
    }

    private func closeGrid() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsGrid = false }
    }

    private func prepare() async {
        if paneState == nil {
            paneState = WorkspacePaneStore.shared.state(for: sessionId)
        }
        guard controllers[sessionId] == nil else { return }
        guard let session = rootSession,
              let project = environment.projectList.projects.first(where: { $0.id == session.projectId })
        else {
            missing = true
            return
        }
        self.project = project
        serverConfig = environment.machines.machine(for: session.serverId)?.serverConfig
            ?? environment.machines.selectedMachine.serverConfig
        await connectChat(sessionId: sessionId)
    }

    private func connectChat(sessionId chatId: UUID) async {
        guard controllers[chatId] == nil,
              let session = session(for: chatId),
              let project = environment.projectList.projects.first(where: { $0.id == session.projectId })
        else { return }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.machines.client(for: session.serverId)
        )
        controller.configureExistingSession(session)
        controllers[chatId] = controller
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

// MARK: - Tab grid

/// The Safari-style tab switcher: a two-column grid of pane previews with
/// close buttons, plus + for an instant new tab.
private struct PaneGridView: View {
    let titleFor: (PaneDescriptorState) -> String
    let cwd: String
    @Binding var paneState: PaneGroupState
    /// Called once the leave animation finishes; the parent drops the cover
    /// without a system animation.
    let onDismiss: () -> Void

    /// Card centers in global space, for the zoom-out anchor.
    @State private var cardFrames: [UUID: CGRect] = [:]
    /// The grid's own Safari-style motion: scales in from slightly zoomed on
    /// appear, and zooms out into the chosen card on leave.
    @State private var entered = false
    @State private var exitAnchor: UnitPoint = .center
    @State private var exiting = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        zoomContainer
            .onAppear {
                withAnimation(.easeOut(duration: 0.22)) { entered = true }
            }
    }

    private var zoomContainer: some View {
        gridNavigation
            .scaleEffect(exiting ? 2.3 : (entered ? 1 : 1.08), anchor: exiting ? exitAnchor : .center)
            .opacity(exiting ? 0 : (entered ? 1 : 0))
    }

    private var gridNavigation: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(paneState.panes) { pane in
                        PaneCard(
                            pane: pane,
                            title: titleFor(pane),
                            isActive: pane.id == paneState.selectedPaneId,
                            onSelect: { select(pane) },
                            onClose: { close(pane) }
                        )
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            cardFrames[pane.id] = frame
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(paneState.panes.count) Tab\(paneState.panes.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        addTab()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New tab")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { leave(toward: anchor(for: paneState.selectedPaneId)) }
                }
            }
        }
    }

    private func anchor(for paneId: UUID?) -> UnitPoint? {
        guard let paneId, let frame = cardFrames[paneId],
              let screen = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.screen.bounds }).first
        else { return nil }
        return UnitPoint(x: frame.midX / screen.width, y: frame.midY / screen.height)
    }

    /// Zooms the grid out into the chosen card, then hands off to the parent.
    private func leave(toward anchor: UnitPoint?) {
        exitAnchor = anchor ?? .center
        withAnimation(.easeIn(duration: 0.26)) { exiting = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            onDismiss()
        }
    }

    private func select(_ pane: PaneDescriptorState) {
        var state = paneState
        state.selectedPaneId = pane.id
        paneState = state
        leave(toward: anchor(for: pane.id))
    }

    /// Any tab can close — chats included, as on macOS. The binding's owner
    /// backfills a New Tab page if the last one goes.
    private func close(_ pane: PaneDescriptorState) {
        var state = paneState
        state.panes.removeAll { $0.id == pane.id }
        if state.selectedPaneId == pane.id {
            state.selectedPaneId = state.panes.first?.id
        }
        paneState = state
        PaneSnapshotCache.shared.images[pane.id] = nil
    }

    /// Instant new tab, macOS-style: no menu — the page itself offers what
    /// the tab becomes.
    private func addTab() {
        var state = paneState
        state.addNewTabPane(inheritedCwd: cwd)
        paneState = state
        leave(toward: nil)
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
