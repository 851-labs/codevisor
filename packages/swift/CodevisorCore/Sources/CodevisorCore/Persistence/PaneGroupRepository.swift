import Foundation

/// Persists pane identities and selection for a session or workspace leaf. Pane
/// identity MUST survive app restarts: the codevisor server keeps one live PTY
/// per pane key with no reaping, so stable keys are what let terminals
/// reattach instead of orphaning shells.
public protocol PaneGroupRepository: Sendable {
  func load(sessionId: UUID) -> PaneGroupState?
  func save(_ state: PaneGroupState, sessionId: UUID)
  func legacyPanes(sessionId: UUID) -> [PaneDescriptorState]
  func removeAll()
}

public extension PaneGroupRepository {
  func legacyPanes(sessionId: UUID) -> [PaneDescriptorState] { [] }
  func removeAll() {}
}

/// File/in-memory storage for pre-workspace sessions and standalone groups.
/// The older bare-session key is read only during workspace migration; active
/// groups use the existing ":center" key. Cached decoding avoids disk reads
/// on every selection change.
public final class DefaultPaneGroupRepository: PaneGroupRepository, @unchecked Sendable {
  private let store: any PersistenceStore
  private let key = "paneGroups"
  private let lock = NSLock()
  private var cache: [String: PaneGroupState]?

  public init(store: any PersistenceStore) {
    self.store = store
  }

  public func load(sessionId: UUID) -> PaneGroupState? {
    loadAll()["\(sessionId.uuidString):center"]
  }

  public func save(_ state: PaneGroupState, sessionId: UUID) {
    var all = loadAll()
    all["\(sessionId.uuidString):center"] = state
    lock.withLock { cache = all }
    do {
      try store.saveData(JSONEncoder().encode(all), forKey: key)
    } catch {
      Log.persistence.error(
        "Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  public func removeAll() {
    lock.withLock { cache = [:] }
    do {
      try store.removeData(forKey: key)
    } catch {
      Log.persistence.error(
        "Failed to clear \(self.key, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  public func legacyPanes(sessionId: UUID) -> [PaneDescriptorState] {
    loadAll()[sessionId.uuidString]?.panes ?? []
  }

  private func loadAll() -> [String: PaneGroupState] {
    if let cached = lock.withLock({ cache }) { return cached }
    let loaded: [String: PaneGroupState]
    if let data = store.loadData(forKey: key) {
      do {
        loaded = try JSONDecoder().decode([String: PaneGroupState].self, from: data)
      } catch {
        // No banner: a lost tab layout is recoverable in place; the
        // quarantined backup and fault log keep it diagnosable.
        handleCorruptPayload(store: store, key: key, data: data, error: error)
        loaded = [:]
      }
    } else {
      loaded = [:]
    }
    lock.withLock { if cache == nil { cache = loaded } }
    return loaded
  }
}
