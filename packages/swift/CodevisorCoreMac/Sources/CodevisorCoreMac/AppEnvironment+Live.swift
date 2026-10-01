import CodevisorCore
import Foundation

extension AppEnvironment {
  /// The macOS composition root: durable SQLite storage plus the
  /// app-managed local server (with its computer-use bridge). iOS builds its
  /// own `live` variant without a local server — that is why this lives in
  /// CodevisorCoreMac rather than the shared module.
  public static func live() throws -> AppEnvironment {
    let storage = try ClientStorageBootstrap.open(directory: CodevisorAppVariant.applicationSupportURL())
    return live(storage: storage)
  }

  /// Builds the main-actor environment after the client database has been
  /// opened and migrated by the app's asynchronous bootstrap surface.
  public static func live(storage: ClientStorage) -> AppEnvironment {
    let store = storage.store
    // Decoded off the main actor by `openAsync` (nil from the synchronous
    // `open`, whose stores read the store themselves).
    let launchSnapshot = storage.launchSnapshot
    let settings = AppSettingsModel(store: store, launchSnapshot: launchSnapshot)
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
      ),
      launchSnapshot: launchSnapshot
    )
    // No composer exists yet: anything staged but undrafted is a leftover.
    composerDrafts.removeUnreferencedAttachmentFiles()
    return AppEnvironment(
      navigationPersistence: store,
      launchSnapshot: launchSnapshot,
      transcriptCache: .shared,
      configCache: ConfigOptionCache(store: store, launchSnapshot: launchSnapshot),
      composerDefaults: ComposerDefaultsStore(store: store),
      composerDrafts: composerDrafts,
      settings: settings,
      machineStore: store,
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
