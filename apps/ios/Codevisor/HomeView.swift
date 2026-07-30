import CodevisorCore
import CodevisorUI
import SwiftUI

/// How the workspace list groups chats — the same organization options as the
/// macOS sidebar. Workspaces on this client are 1:1 with chats today, so the
/// workspace grouping renders the same rows as Agents until multi-chat
/// workspaces sync.
private enum HomeOrganization: String, CaseIterable {
    case compact
    case byWorkspace
    case byProject

    var title: String {
        switch self {
        case .compact: "Agents"
        case .byWorkspace: "Workspaces"
        case .byProject: "Projects"
        }
    }
}

/// The screens this list pushes. One route type (rather than a `[UUID]` path
/// plus a separate boolean destination for the compose page) so the new-chat
/// handoff can replace the whole stack in ONE state change: a send swaps
/// compose → workspace atomically instead of popping and then pushing, which
/// read as two stacked slide transitions.
private enum HomeRoute: Hashable {
    case newChat
    case workspace(UUID)
}

/// Ordering, matching the macOS sidebar: manual (drag), priority + recency,
/// or creation time.
private enum HomeOrder: String, CaseIterable {
    case none
    case updated
    case created

    var title: String {
        switch self {
        case .none: "None"
        case .updated: "Last updated"
        case .created: "Created"
        }
    }
}

/// The workspaces navigation screen: every workspace on the paired machine,
/// organized and ordered like the macOS sidebar, with settings at the top
/// left, the organize menu at the top right, and a fixed New Chat call
/// to action at the bottom.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    @AppStorage("sidebar.organization") private var organizationRaw = HomeOrganization.compact.rawValue
    @AppStorage("sidebar.order") private var orderRaw = HomeOrder.updated.rawValue
    @AppStorage("sidebar.manualSessionOrder") private var manualSessionOrder = ""
    @AppStorage("ios.onboarding.dismissed") private var onboardingDismissed = false
    @State private var onboardingStart = OnboardingView.Step.welcome
    // Bootstrap adds the dev machine a beat after first render; the grace
    // period keeps onboarding from flashing over an already-paired install.
    @State private var readyForOnboarding = false
    @State private var isShowingSettings = false
    @State private var isManagingMachines = false
    @State private var path: [HomeRoute] = []
    @State private var pendingDeeplink: MachineDeeplink?
    @State private var deeplinkError: String?

    private var organization: HomeOrganization {
        HomeOrganization(rawValue: organizationRaw) ?? .compact
    }

    private var order: HomeOrder {
        HomeOrder(rawValue: orderRaw) ?? .updated
    }

    private var machines: MachineController { environment.machines }
    private var projectList: ProjectListModel { environment.projectList }

    private var hasRemoteMachines: Bool {
        machines.machines.contains { !$0.isLocal }
    }

    /// Onboarding presents itself whenever no machine is paired. There is no
    /// in-flow skip (the app is useless without a machine); the dismissed
    /// flag only records programmatic closes — e.g. pairing while the cover
    /// is up — and the empty state re-arms it.
    private var showsOnboarding: Binding<Bool> {
        Binding(
            get: { readyForOnboarding && !onboardingDismissed && !hasRemoteMachines },
            set: { if !$0 { onboardingDismissed = true } }
        )
    }

    /// Active chats on the selected machine, in the chosen order.
    private var visibleSessions: [ChatSession] {
        let sessions = projectList.sessions
            .filter { $0.serverId == machines.selectedMachineId && !$0.isArchived }
        switch order {
        case .updated:
            // Priority first (errors, waiting, unread), then recency — the
            // macOS sidebar's default.
            return sessions.sorted { lhs, rhs in
                let lp = priority(for: lhs)
                let rp = priority(for: rhs)
                if lp != rp { return lp < rp }
                return (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
            }
        case .created:
            return sessions.sorted { $0.createdAt > $1.createdAt }
        case .none:
            let ordered = manualSessionOrder
                .split(separator: "\n")
                .compactMap { UUID(uuidString: String($0)) }
            var index: [UUID: Int] = [:]
            for (position, id) in ordered.enumerated() { index[id] = position }
            return sessions.sorted { lhs, rhs in
                let li = index[lhs.id] ?? Int.max
                let ri = index[rhs.id] ?? Int.max
                if li != ri { return li < ri }
                return (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
            }
        }
    }

    /// Sort tier for a chat row. Every state checked here is visible on the
    /// row as `SessionRow.statusDot` in the same precedence (error →
    /// attention → in progress → unread, matching the macOS sidebar); keep
    /// the two in sync. If sorting ever consults a state the dot doesn't
    /// show (the macOS sidebar once sorted a spinning chat by its hidden
    /// unread count), opening a chat reorders the list with no visible
    /// state change.
    private func priority(for session: ChatSession) -> Int {
        if session.hasUnreadError { return 0 }
        if session.actionRequired || session.pendingPlanApproval { return 1 }
        // Classification follows the icon precedence (a mid-run agent with
        // buffered unread turns shows the spinner, so it classifies as in
        // progress), while unread as a tier still ranks above in progress —
        // the same split the macOS sidebar makes.
        if ChatControllerCache.shared.isInProgress(session) { return 3 }
        if session.unreadCount > 0 { return 2 }
        return 4
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !hasRemoteMachines {
                    noMachineState
                } else if visibleSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // One glass group on the left: settings, then the machine
                // picker, mirroring the macOS toolbar's machine menu.
                ToolbarItemGroup(placement: .topBarLeading) {
                    machineMenu
                    settingsButton
                }
                ToolbarItem(placement: .topBarTrailing) { organizeMenu }
            }
            .safeAreaInset(edge: .bottom) {
                // The empty states carry their own single call to action; a
                // second floating button would just compete with it.
                if hasRemoteMachines && !visibleSessions.isEmpty {
                    newChatButton
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .newChat:
                    // The same screen, opened as a draft: it hosts the new
                    // chat's composer and becomes that workspace in place on
                    // the first send. No second screen, no hand-off, no
                    // mid-send remount.
                    WorkspaceScreen(sessionId: nil)
                case let .workspace(sessionId):
                    WorkspaceScreen(sessionId: sessionId)
                }
            }
            .refreshable {
                await projectList.refreshFromServer()
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
            }
            .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenSettings)) { _ in
                isShowingSettings = true
            }
            .sheet(isPresented: $isManagingMachines) {
                NavigationStack {
                    MachinesSettingsScreen()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isManagingMachines = false }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: showsOnboarding) {
                onboardingStart = .welcome
            } content: {
                OnboardingView(start: onboardingStart)
                    // The QR flow lands here: alerts must present over the
                    // cover, so it carries its own copy of the deeplink
                    // alerts, active while it is the visible context.
                    .modifier(
                        MachineDeeplinkAlerts(
                            pending: $pendingDeeplink,
                            error: $deeplinkError,
                            isActive: true,
                            confirm: confirmDeeplink
                        )
                    )
            }
            // `codevisor://add-machine` deeplinks — the QR that `codevisor
            // setup`/`codevisor qr` prints, or the camera-scanned banner.
            // Never auto-add: the token grants full agent access, so an
            // explicit confirmation always sits between the link and the
            // machine list (same contract as macOS).
            .onOpenURL { url in
                guard let link = MachineDeeplink.parse(url) else { return }
                pendingDeeplink = link
            }
            .modifier(
                MachineDeeplinkAlerts(
                    pending: $pendingDeeplink,
                    error: $deeplinkError,
                    isActive: !showsOnboarding.wrappedValue,
                    confirm: confirmDeeplink
                )
            )
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                readyForOnboarding = true
            }
        }
    }

    /// Validated add from a confirmed deeplink: unreachable hosts and
    /// rejected tokens surface in the error alert instead of as a broken
    /// machine. Success selects the machine, which also closes onboarding.
    private func confirmDeeplink(_ link: MachineDeeplink) {
        pendingDeeplink = nil
        Task {
            do {
                let machine = try await environment.machines.addRemoteValidating(
                    host: link.hostWithPort,
                    name: link.name,
                    token: link.token
                )
                environment.machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
            } catch {
                deeplinkError = ErrorReporter.userFacingMessage(for: error)
            }
        }
    }

    // MARK: - Lists

    private var sessionList: some View {
        List {
            switch organization {
            case .compact, .byWorkspace:
                Section {
                    ForEach(visibleSessions) { session in
                        NavigationLink(value: HomeRoute.workspace(session.id)) {
                            SessionRow(
                                session: session,
                                projectName: projectName(for: session),
                                harnessSymbol: harnessSymbol(for: session)
                            )
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                _ = environment.archiveSessionAndWorkspaceIfEmpty(session)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.orange)
                        }
                    }
                    .onMove { source, destination in
                        // Drag-to-reorder only means something in manual
                        // order; other orders recompute on the next change.
                        guard order == .none else { return }
                        moveSessions(from: source, to: destination)
                    }
                }
            case .byProject:
                ForEach(projectList.activeProjects.filter { !$0.isScratch }) { project in
                    let sessions = visibleSessions.filter { $0.projectId == project.id }
                    if !sessions.isEmpty {
                        Section {
                            ForEach(sessions) { session in
                                NavigationLink(value: HomeRoute.workspace(session.id)) {
                                    SessionRow(
                                        session: session,
                                        projectName: nil,
                                        harnessSymbol: harnessSymbol(for: session)
                                    )
                                }
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        _ = environment.archiveSessionAndWorkspaceIfEmpty(session)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.orange)
                                }
                            }
                        } header: {
                            Label(project.name, systemImage: project.symbolName)
                        }
                    }
                }
                // Chats without a real project (scratch-backed) are not a
                // project: they sit in one headerless section at the root.
                let looseSessions = visibleSessions.filter { session in
                    projectList.activeProjects.first {
                        $0.id == session.projectId
                    }?.isScratch != false
                }
                if !looseSessions.isEmpty {
                    Section {
                        ForEach(looseSessions) { session in
                            NavigationLink(value: HomeRoute.workspace(session.id)) {
                                SessionRow(
                                    session: session,
                                    projectName: nil,
                                    harnessSymbol: harnessSymbol(for: session)
                                )
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    _ = environment.archiveSessionAndWorkspaceIfEmpty(session)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Room for the floating call to action so the last row can scroll
        // clear of it.
        .contentMargins(.bottom, 64, for: .scrollContent)
    }

    private func moveSessions(from source: IndexSet, to destination: Int) {
        var ids = visibleSessions.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        manualSessionOrder = ids.map(\.uuidString).joined(separator: "\n")
    }

    private func projectName(for session: ChatSession) -> String? {
        projectList.activeProjects.first { $0.id == session.projectId }?.name
    }

    /// Fallback SF symbol from the machine's cached capabilities, for
    /// harnesses without a bundled brand icon.
    private func harnessSymbol(for session: ChatSession) -> String {
        environment.configCache.capabilities(forServer: session.serverId)
            .first { $0.harness.id == session.harnessId }?
            .harness.symbolName ?? "cpu"
    }

    /// No machine paired (all machines removed): everything routes back
    /// into the onboarding connect page.
    private var noMachineState: some View {
        ContentUnavailableView {
            Label {
                Text("No Machine Connected")
            } icon: {
                Image("hunk")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.tertiary)
            }
        } description: {
            Text("Codevisor runs coding agents on your own Mac or Linux machine and streams them here.")
        } actions: {
            Button {
                onboardingStart = .connect
                onboardingDismissed = false
            } label: {
                Text("Connect a Machine")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }

    /// A machine is paired but has no active workspaces yet.
    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Workspaces")
            } icon: {
                Image("hunk")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.tertiary)
            }
        } description: {
            Text("Workspaces are where agents work on \(machines.selectedMachine.name). Start your first one.")
        } actions: {
            Button {
                path.append(.newChat)
            } label: {
                Label("New Chat", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }

    // MARK: - Toolbar

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    /// The machine picker, as on macOS: paired machines with the selection
    /// checked, then Manage Machines at the bottom.
    private var machineMenu: some View {
        Menu {
            ForEach(machines.machines.filter { !$0.isLocal }) { machine in
                Button {
                    machines.selectMachine(machine.id)
                    Task { await environment.prepareSelectedMachine() }
                } label: {
                    if machine.id == machines.selectedMachineId {
                        Label(machine.name, systemImage: "checkmark")
                    } else {
                        Text(machine.name)
                    }
                }
            }
            Divider()
            Button {
                isManagingMachines = true
            } label: {
                Label("Manage Machines…", systemImage: "desktopcomputer")
            }
        } label: {
            Image(systemName: machines.selectedMachine.resolvedAppearance.symbolName)
        }
        .accessibilityLabel("Machine: \(machines.selectedMachine.name)")
    }

    /// The macOS sidebar's organize menu: Organization and Order pickers,
    /// plus reset when manually ordered.
    private var organizeMenu: some View {
        Menu {
            Picker("Organization", selection: $organizationRaw) {
                ForEach(HomeOrganization.allCases, id: \.rawValue) { organization in
                    Text(organization.title).tag(organization.rawValue)
                }
            }
            .pickerStyle(.menu)
            Picker("Order by", selection: $orderRaw) {
                ForEach(HomeOrder.allCases, id: \.rawValue) { order in
                    Text(order.title).tag(order.rawValue)
                }
            }
            .pickerStyle(.menu)
            if order == .none {
                Divider()
                Button("Reset manual order") { manualSessionOrder = "" }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Organize workspaces")
    }

    private var newChatButton: some View {
        Button {
            path.append(.newChat)
        } label: {
            Label("New chat", systemImage: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .padding(.bottom, 8)
        .accessibilityLabel("New chat")
    }
}

/// One chat row, Mail-style: unread/status dot on the far left, the
/// harness's icon, then the title over "workspace · worktree". No timestamp —
/// ordering already tells recency.
private struct SessionRow: View {
    let session: ChatSession
    let projectName: String?
    let harnessSymbol: String

    private var needsAttention: Bool { session.actionRequired || session.pendingPlanApproval }
    private var hasError: Bool { session.hasUnreadError }
    private var isUnread: Bool { session.unreadCount > 0 }
    private var isInProgress: Bool { ChatControllerCache.shared.isInProgress(session) }

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 38, height: 38)
                .overlay {
                    // The same bundled brand glyphs as the macOS harness
                    // picker, kept quiet like Mail's sender avatars.
                    HarnessIconView(
                        harnessId: session.harnessId,
                        fallbackSymbolName: harnessSymbol,
                        size: 20
                    )
                    .foregroundStyle(.secondary)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "New Chat" : session.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let projectName {
                        Text(projectName)
                    }
                    if let worktree = session.worktreeName, !worktree.isEmpty {
                        if projectName != nil { Text("·") }
                        Text(worktree)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
    }

    /// Error → attention → in progress → unread — the exact precedence of the
    /// macOS sidebar's `ChatSessionLeadingIcon`, so a mid-run agent shows the
    /// working glyph even while it has buffered unread turns.
    @ViewBuilder private var statusDot: some View {
        if hasError {
            Circle().fill(.red).frame(width: 8, height: 8)
        } else if needsAttention {
            Circle().fill(.orange).frame(width: 8, height: 8)
        } else if isInProgress {
            AgentActivityIndicator()
                .frame(width: 8, height: 8)
        } else if isUnread {
            Circle().fill(.blue).frame(width: 8, height: 8)
        } else {
            Circle().fill(.clear).frame(width: 8, height: 8)
        }
    }
}

/// The macOS sidebar's Herdr-inspired working glyph, ported: ten braille
/// frames advancing at roughly eight steps per second in the status slot.
private struct AgentActivityIndicator: View {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: reduceMotion)) { context in
            let frame = reduceMotion ? Self.frames[0] : Self.frame(at: context.date)
            Text(frame)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.identity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private static func frame(at date: Date) -> String {
        let tick = Int(date.timeIntervalSinceReferenceDate * 8)
        return frames[tick % frames.count]
    }
}

// MARK: - Machine deeplink alerts

/// The confirm + error alerts for `codevisor://add-machine` deeplinks,
/// mirroring the macOS handler. Applied twice — to the home content and to
/// the onboarding cover — with `isActive` selecting whichever is the visible
/// presentation context, so the same pending state presents in exactly one
/// place.
private struct MachineDeeplinkAlerts: ViewModifier {
    @Binding var pending: MachineDeeplink?
    @Binding var error: String?
    let isActive: Bool
    let confirm: (MachineDeeplink) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Add Remote Machine?",
                isPresented: Binding(
                    get: { isActive && pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending
            ) { deeplink in
                Button("Add \(deeplink.displayName)") { confirm(deeplink) }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { deeplink in
                Text(
                    """
                    “\(deeplink.displayName)” (\(deeplink.hostWithPort)) will be added to your \
                    machines. Codevisor will be able to run agents and read files on it.
                    """
                )
            }
            .alert(
                "Couldn't Add Machine",
                isPresented: Binding(
                    get: { isActive && error != nil },
                    set: { if !$0 { error = nil } }
                ),
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) { error = nil }
            } message: { message in
                Text(message)
            }
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment.preview())
}
