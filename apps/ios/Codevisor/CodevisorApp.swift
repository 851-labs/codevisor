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
                HomeView()
                    // Order matters: ThemedRoot reads AppEnvironment, so the
                    // environment injection must wrap it (i.e. come after).
                    .modifier(ThemedRoot())
                    .environment(environment)
                    .preferredColorScheme(colorScheme(for: environment))
                    .task { await bootstrap(environment: environment) }
                    .onChange(of: scenePhase) { _, phase in
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
            } else if let startupError {
                ClientDataStartupFailureView(
                    message: startupError,
                    retry: retryStartup
                )
            } else {
                ClientDataStartupView()
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
        // Refreshes machine status, pulls projects/sessions, starts the
        // event-stream sync. On iOS the selected machine is always remote;
        // prepareSelectedMachine never starts a local server here.
        // The dev remote that `bun run dev:ios` starts is never paired
        // automatically — it shows up as a quick add in onboarding and
        // Settings → Machines (CodevisorAppVariant.developmentRemote).
        await environment.prepareSelectedMachine()
        // Restore the cloud account session (or adopt the dev cloud token);
        // nothing at boot depends on it, so it runs after machine prep.
        await environment.cloud.bootstrap()
        hasCompletedBootstrap = true
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
            let shouldRecover = self.previousSignature != nil
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
