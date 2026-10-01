import Foundation

/// The persisted state the first window renders from, read and decoded away
/// from the main actor.
///
/// Every machine's navigation cache (its whole session list), the
/// capabilities catalog, the composer drafts, and the settings would
/// otherwise be SQLite reads plus JSON decodes on the main thread while the
/// environment is constructed. `ClientStorageBootstrap.openAsync` builds this
/// in its background work and the main-actor stores adopt the decoded values,
/// so what the UI shows first is unchanged: the cache is there the moment
/// the environment exists.
///
/// A snapshot describes its store only at the moment it was read. Hand it to
/// the stores of the one environment constructed right after it, before
/// anything else writes to that store.
public struct ClientLaunchSnapshot: Sendable {
  let navigationCaches: [String: MachineNavigationCache]
  let configOptions: ConfigOptionCache.Persisted
  let composerDrafts: ComposerDraftStore.Persisted
  let settings: AppSettings

  /// Reads and decodes on the calling thread, which must not be the main
  /// thread: `openAsync` calls it from its detached bootstrap work.
  static func read(from store: any PersistenceStore) -> ClientLaunchSnapshot {
    // Land any save still queued for this store so the snapshot is current.
    PersistenceEncoding.drain()
    return ClientLaunchSnapshot(
      navigationCaches: NavigationCacheStore.loadCaches(from: store),
      configOptions: ConfigOptionCache.loadPersisted(from: store),
      composerDrafts: ComposerDraftStore.loadPersisted(from: store),
      settings: AppSettingsModel.loadSettings(from: store)
    )
  }
}
