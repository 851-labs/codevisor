import CodevisorCore
import Foundation

extension AppEnvironment {
  /// The macOS composition root: durable SQLite storage plus the
  /// app-managed local server (with its computer-use bridge). iOS builds its
  /// own `live` variant without a local server — that is why this lives in
  /// CodevisorCoreMac rather than the shared module.
  public static func live() throws -> AppEnvironment {
    let storage = try ClientStorageBootstrap.open(
      directory: CodevisorAppVariant.applicationSupportURL(),
      credentials: KeychainMachineCredentialStore.shared
    )
    return live(storage: storage)
  }

  /// Builds the main-actor environment after the client database has been
  /// opened and migrated by the app's asynchronous bootstrap surface.
  public static func live(storage: ClientStorage) -> AppEnvironment {
    let store = storage.store
    let settings = AppSettingsModel(store: store)
    let serverClient = CodevisorServerClient(config: .localDefault)
    let localServer = LocalCodevisorServer(
      client: serverClient,
      allowsDevelopmentLaunch: CodevisorAppVariant.isDevelopment,
      computerUseBridge: ComputerUseBridge(
        supportDirectory: CodevisorAppVariant.serverDataDirectoryURL()
      )
    )
    return AppEnvironment(
      projectRepository: DefaultProjectRepository(store: store),
      sessionRepository: DefaultSessionRepository(store: store),
      configCache: ConfigOptionCache(store: store),
      composerDefaults: ComposerDefaultsStore(store: store),
      composerDrafts: ComposerDraftStore(store: store),
      settings: settings,
      machineStore: store,
      machineCredentialStore: KeychainMachineCredentialStore.shared,
      cloudCredentialStore: KeychainCloudCredentialStore.shared,
      legacyCacheMigrationStore: store,
      paneGroups: DefaultPaneGroupRepository(store: store),
      workspaces: DefaultWorkspaceRepository(store: store),
      localServer: localServer,
      appUpdate: AppUpdateModel(
        currentVersion: AppUpdateModel.bundleVersion(),
        currentBuildNumber: AppUpdateModel.bundleBuildNumber(),
        allowsAlphaUpdates: settings.alphaUpdatesEnabled
      ),
      customThemesDirectory: ThemeManager.defaultCustomThemesDirectory()
    )
  }
}
