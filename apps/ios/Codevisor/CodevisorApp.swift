import CodevisorCore
import CodevisorTheming
import CodevisorUI
import Combine
import Network
import SwiftUI

@main
struct CodevisorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var networkPath = NetworkPathObserver()
    @State private var environment: AppEnvironment?
    @State private var startupError: String?
    @State private var startupInProgress = false
    @State private var hasCompletedBootstrap = false
    @State private var recoveryInProgress = false

    init() {
        _environment = State(initialValue: nil)
        _startupError = State(initialValue: nil)
    }

    var body: some Scene {
        WindowGroup {
            if let environment {
                if shouldWaitForCloudRestore(environment: environment) {
                    // A cloud-only machine list is unknown until the persisted
                    // account session has been validated and its first machine
                    // snapshot arrives. Keep the honest startup state mounted
                    // instead of briefly claiming no machine is connected.
                    CodevisorStartupSplashView()
                        .preferredColorScheme(colorScheme(for: environment))
                        .task { await environment.cloud.bootstrap() }
                } else {
                    HomeView()
                        // Order matters: ThemedRoot reads AppEnvironment, so the
                        // environment injection must wrap it (i.e. come after).
                        .modifier(ThemedRoot())
                        .environment(environment)
                        .preferredColorScheme(colorScheme(for: environment))
                        .task { await bootstrap(environment: environment) }
                        .onChange(of: scenePhase, initial: true) { _, phase in
                            // Read = focus: a backgrounded app must not mark
                            // the open chat read while finishes land.
                            environment.attentionCoordinator.setApplicationActive(
                                phase == .active
                            )
                            guard phase == .active, hasCompletedBootstrap else { return }
                            Task { await recoverAfterForeground(environment: environment) }
                        }
                        .onChange(of: networkPath.recoveryToken) { _, _ in
                            guard scenePhase == .active, hasCompletedBootstrap else { return }
                            Task { await recoverAfterForeground(environment: environment) }
                        }
                    // `codevisor://add-machine` deeplinks are handled inside
                    // HomeView, which owns the confirmation alerts and can present
                    // them over the onboarding cover.
                }
            } else if let startupError {
                ClientDataStartupFailureView(
                    message: startupError,
                    retry: retryStartup
                )
            } else {
                CodevisorStartupSplashView()
                    .task { await startEnvironmentIfNeeded() }
            }
        }
    }

    /// Applies the Appearance setting; `.system` follows the device.
    private func colorScheme(for environment: AppEnvironment) -> ColorScheme? {
        switch environment.settings.settings.themeMode {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    /// Locally configured remotes are available synchronously and need no
    /// launch gate. Cloud-only installs (and persisted cloud selections) do:
    /// their apparent empty list is merely unresolved until account bootstrap.
    private func shouldWaitForCloudRestore(environment: AppEnvironment) -> Bool {
        guard environment.cloud.isRestoringPersistedSession else { return false }
        let machines = environment.machines
        let hasConfiguredRemote = machines.machines.contains { !$0.isLocal }
        return machines.selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix)
            || !hasConfiguredRemote
    }

    /// A minimal iOS composition root: durable SQLite storage, no local
    /// server (iOS is a pure client — `localServer` stays nil).
    private static func makeEnvironment(storage: ClientStorage) -> AppEnvironment {
        let store = storage.store
        return AppEnvironment(
            projectRepository: DefaultProjectRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: store),
            configCache: ConfigOptionCache(store: store),
            composerDefaults: ComposerDefaultsStore(store: store),
            composerDrafts: ComposerDraftStore(store: store),
            settings: AppSettingsModel(store: store),
            machineStore: store,
            machineCredentialStore: KeychainMachineCredentialStore.shared,
            cloudCredentialStore: KeychainCloudCredentialStore.shared,
            legacyCacheMigrationStore: store,
            paneGroups: DefaultPaneGroupRepository(store: store),
            workspaces: DefaultWorkspaceRepository(store: store)
        )
    }

    private func retryStartup() {
        startupError = nil
        Task { await startEnvironmentIfNeeded() }
    }

    @MainActor
    private func startEnvironmentIfNeeded() async {
        guard environment == nil, !startupInProgress else { return }
        startupInProgress = true
        defer { startupInProgress = false }
        do {
            let directory = URL.applicationSupportDirectory
                .appendingPathComponent("Codevisor", isDirectory: true)
            let storage = try await ClientStorageBootstrap.openAsync(
                directory: directory,
                credentials: KeychainMachineCredentialStore.shared
            )
            environment = Self.makeEnvironment(storage: storage)
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func bootstrap(environment: AppEnvironment) async {
        let machines = environment.machines
        let selectedIsConfiguredRemote = machines.machines.contains {
            $0.id == machines.selectedMachineId && !$0.isLocal
        }
        if selectedIsConfiguredRemote {
            // Locally persisted remotes resolve synchronously. Preserve their
            // fast path and collect status first so the later cloud snapshot
            // can deduplicate the same machine by its advertised device id.
            await environment.prepareSelectedMachine()
            await environment.cloud.bootstrap()
        } else {
            // Cloud entries are synthesized rather than stored in the local
            // registry, so restore them before resolving and preparing a
            // persisted cloud selection (or auto-selecting on a fresh setup).
            await environment.cloud.bootstrap()
            await environment.prepareSelectedMachine()
        }
        hasCompletedBootstrap = true
        // Fleet update sweep off the critical path: the Settings badge and
        // Updates screen read what this populates. A pending update-all
        // session (a run died mid-way) resumes first.
        Task {
            await environment.updateCenter.resumePendingSessionIfNeeded()
            await environment.updateCenter.refresh()
            await environment.configSync.synchronizeAll()
        }
    }

    /// iOS can preserve a half-open URLSession WebSocket across suspension or
    /// a network handoff. Replace it on foreground, then re-prepare the
    /// selected machine so metadata and event streams reconcile immediately.
    private func recoverAfterForeground(environment: AppEnvironment) async {
        guard !recoveryInProgress else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        await environment.cloud.reconnectHub()
        await environment.prepareSelectedMachine()
        // Re-sweep fleet update state with transport restored.
        Task { await environment.updateCenter.refresh() }
        // With transport restored, re-verify every in-flight chat against
        // durable history. Stream replay heals missed events on its own, but
        // not a turn whose state moved while the app was suspended in a way
        // the replaced sockets never saw.
        await ChatControllerCache.shared.reconcileInFlightControllers()
    }
}

/// The brief full-screen state shown while iOS opens its local data and
/// restores a persisted cloud session. Keep it visually branded but quiet:
/// startup normally lasts only a moment.
private struct CodevisorStartupSplashView: View {
    @State private var showsSpinner = false

    private var title: String {
        guard CodevisorAppVariant.isDevelopment,
            CodevisorAppVariant.developmentInstanceID != nil
        else { return "Codevisor" }
        return "Codevisor (\(CodevisorAppVariant.developmentWorktreeName))"
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                CodevisorAppIconView(size: 112)

                Text(title)
                    .font(.title2.weight(.semibold))

                ZStack {
                    if showsSpinner {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.secondary)
                            .transition(.opacity)
                    }
                }
                .frame(height: 24)
                .accessibilityHidden(!showsSpinner)
            }
            .task {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    showsSpinner = true
                }
            }
        }
    }
}

/// Emits only after a real path transition (not the monitor's initial
/// snapshot). A satisfied Wi-Fi/cellular handoff is enough reason to replace
/// a WebSocket whose old TCP path can remain half-open indefinitely.
private final class NetworkPathObserver: ObservableObject, @unchecked Sendable {
    @Published private(set) var recoveryToken = 0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.codevisor.ios.network-path")
    private var previousSignature: String?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = [
                String(describing: path.status),
                path.usesInterfaceType(.wifi) ? "wifi" : "",
                path.usesInterfaceType(.cellular) ? "cellular" : "",
                path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "",
                path.isExpensive ? "expensive" : "",
                path.isConstrained ? "constrained" : "",
            ].joined(separator: ":")
            let shouldRecover =
                self.previousSignature != nil
                && self.previousSignature != signature
                && path.status == .satisfied
            self.previousSignature = signature
            guard shouldRecover else { return }
            DispatchQueue.main.async { [weak self] in
                self?.recoveryToken &+= 1
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private struct ClientDataStartupFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Codevisor Couldn't Open Its Data", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("The app stopped before loading or syncing so your existing data remains intact.\n\n\(message)")
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}
