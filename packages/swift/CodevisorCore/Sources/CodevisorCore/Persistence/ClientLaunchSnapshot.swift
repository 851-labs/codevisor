import Foundation

public struct ClientLaunchSnapshot: Sendable {
  let navigationCaches: [String: MachineNavigationCache]
  let configOptions: ConfigOptionCache.Persisted
  let composerDrafts: ComposerDraftStore.Persisted
  let settings: AppSettings

  static func read(from store: any PersistenceStore) -> ClientLaunchSnapshot {
    PersistenceEncoding.drain()
    return ClientLaunchSnapshot(
      navigationCaches: NavigationCacheStore.loadCaches(from: store),
      configOptions: ConfigOptionCache.loadPersisted(from: store),
      composerDrafts: ComposerDraftStore.loadPersisted(from: store),
      settings: AppSettingsModel.loadSettings(from: store)
    )
  }
}
