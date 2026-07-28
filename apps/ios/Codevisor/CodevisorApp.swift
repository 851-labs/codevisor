import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI

@main
struct CodevisorApp: App {
    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: Self.makeEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                // Order matters: ThemedRoot reads AppEnvironment, so the
                // environment injection must wrap it (i.e. come after).
                .modifier(ThemedRoot())
                .environment(environment)
                .preferredColorScheme(colorScheme)
                .task { await bootstrap() }
            // `codevisor://add-machine` deeplinks are handled inside
            // HomeView, which owns the confirmation alerts and can present
            // them over the onboarding cover.
        }
    }

    /// Applies the Appearance setting; `.system` follows the device.
    private var colorScheme: ColorScheme? {
        switch environment.settings.settings.themeMode {
        case .light: .light
        case .dark: .dark
        case .system: nil
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
        // Refreshes machine status, pulls projects/sessions, starts the
        // event-stream sync. On iOS the selected machine is always remote;
        // prepareSelectedMachine never starts a local server here.
        // The dev remote that `bun run dev:ios` starts is never paired
        // automatically — it shows up as a quick add in onboarding and
        // Settings → Machines (CodevisorAppVariant.developmentRemote).
        await environment.prepareSelectedMachine()
    }
}
