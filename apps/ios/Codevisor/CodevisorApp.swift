import CodevisorCore
import SwiftUI

@main
struct CodevisorApp: App {
    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: Self.makeEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
        }
    }

    /// A minimal iOS composition root: durable file-system stores, no local
    /// server (iOS is a pure client — `localServer` stays nil). Machine
    /// pairing and the full iOS `live()` variant arrive with Phase 3.
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
}
