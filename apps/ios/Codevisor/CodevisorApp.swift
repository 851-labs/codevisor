import CodevisorCore
import CodevisorUI
import SwiftUI
import os

@main
struct CodevisorApp: App {
    @State private var environment: AppEnvironment
    private let log = Logger(subsystem: Log.subsystem, category: "ios-app")

    init() {
        _environment = State(initialValue: Self.makeEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(environment)
                .task { await bootstrap() }
                .onOpenURL { url in
                    handleDeeplink(url)
                }
        }
    }

    /// A minimal iOS composition root: durable file-system stores, no local
    /// server (iOS is a pure client — `localServer` stays nil).
    private static func makeEnvironment() -> AppEnvironment {
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("Codevisor", isDirectory: true)
        let store = FileSystemStore(directory: directory)
        return AppEnvironment(
            projectRepository: DefaultProjectRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: store),
            configCache: ConfigOptionCache(store: store),
            composerDefaults: ComposerDefaultsStore(store: store),
            composerDrafts: ComposerDraftStore(store: store),
            settings: AppSettingsModel(store: store),
            machineStore: store,
            paneGroups: DefaultPaneGroupRepository(store: store),
            workspaces: DefaultWorkspaceRepository(store: store),
            scratchpads: DefaultScratchpadRepository(store: store)
        )
    }

    private func bootstrap() async {
        addDevelopmentMachineIfNeeded()
        // Refreshes machine status, pulls projects/sessions, starts the
        // event-stream sync. On iOS the selected machine is always remote;
        // prepareSelectedMachine never starts a local server here.
        await environment.prepareSelectedMachine()
    }

    /// `bun run dev:ios` passes the dev remote's coordinates in the launch
    /// environment (the iOS analog of the macOS one-click "add test remote").
    private func addDevelopmentMachineIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["CODEVISOR_DEV_SERVER_URL"],
              let url = URL(string: urlString),
              let host = url.host() else { return }
        let hostWithPort = url.port.map { "\(host):\($0)" } ?? host
        let machines = environment.machines
        if let existing = machines.machines.first(where: {
            $0.baseURL.host() == url.host() && $0.baseURL.port == url.port
        }) {
            machines.selectMachine(existing.id)
            return
        }
        do {
            let machine = try machines.addRemote(
                host: hostWithPort,
                name: env["CODEVISOR_DEV_SERVER_NAME"] ?? "Dev Server",
                token: env["CODEVISOR_DEV_SERVER_TOKEN"]
            )
            machines.selectMachine(machine.id)
            log.log("Added dev machine \(machine.name, privacy: .public)")
        } catch {
            log.error("Adding dev machine failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `codevisor://add-machine?host=&port=&token=&name=`, printed by
    /// `codevisor setup` on a remote machine (and encoded in its QR code).
    private func handleDeeplink(_ url: URL) {
        guard let link = MachineDeeplink.parse(url) else { return }
        let machines = environment.machines
        Task {
            do {
                let machine = try await machines.addRemoteValidating(
                    host: link.hostWithPort,
                    name: link.displayName,
                    token: link.token
                )
                machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
            } catch {
                log.error("Deeplink machine add failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
