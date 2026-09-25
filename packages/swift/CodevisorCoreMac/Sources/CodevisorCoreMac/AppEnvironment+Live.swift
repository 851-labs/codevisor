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
    let composerDrafts = ComposerDraftStore(
      store: store,
      attachmentFiles: ComposerAttachmentFileStore(
        root: CodevisorAppVariant.applicationSupportURL()
          .appendingPathComponent("ComposerAttachments", isDirectory: true)
      )
    )
    // No composer exists yet: anything staged but undrafted is a leftover.
    composerDrafts.removeUnreferencedAttachmentFiles()
    return AppEnvironment(
      navigationPersistence: store,
      transcriptCache: .shared,
      configCache: ConfigOptionCache(store: store),
      composerDefaults: ComposerDefaultsStore(store: store),
      composerDrafts: composerDrafts,
      settings: settings,
      machineStore: store,
      machineCredentialStore: KeychainMachineCredentialStore.shared,
      cloudCredentialStore: KeychainCloudCredentialStore.shared,
      paneGroups: DefaultPaneGroupRepository(store: store),
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
