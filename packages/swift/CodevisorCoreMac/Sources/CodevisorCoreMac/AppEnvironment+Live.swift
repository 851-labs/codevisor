import CodevisorCore
import Foundation

extension AppEnvironment {
  public static func live() throws -> AppEnvironment {
    let storage = try ClientStorageBootstrap.open(directory: CodevisorAppVariant.applicationSupportURL())
    return live(storage: storage)
  }

  public static func live(storage: ClientStorage) -> AppEnvironment {
    let store = storage.store
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
