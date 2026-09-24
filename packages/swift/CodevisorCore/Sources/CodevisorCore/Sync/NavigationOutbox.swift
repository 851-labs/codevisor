import Foundation

/// A request in the outbox and how far it has got.
public struct NavigationOutboxEntry: Codable, Equatable, Sendable, Identifiable {
  public enum State: Codable, Equatable, Sendable {
    /// Not sent yet, or sent without a definite answer.
    case pending
    /// The server accepted it. Its change is in the server's event log at or
    /// before `cursor`; the entry stays visible until this device's cached
    /// copy of that machine has caught up to that point, so the UI never
    /// flickers back to the old value in between.
    case awaiting(cursor: Int, acceptedAt: Date)
  }

  public let id: UUID
  public let machineId: String
  public var intent: NavigationIntent
  public var state: State
  public var attempts: Int

  init(id: UUID = UUID(), machineId: String, intent: NavigationIntent) {
    self.id = id
    self.machineId = machineId
    self.intent = intent
    self.state = .pending
    self.attempts = 0
  }
}

/// The user's changes to server state that the server hasn't confirmed yet,
/// in the order they were made, saved so they survive the app being killed.
///
/// An entry leaves the outbox when the server rejects it (the cached server
/// state is then what the user sees), when a delete finds nothing to delete,
/// or once the server accepted it and this device's cache has caught up.
@MainActor
final class NavigationOutbox {
  nonisolated static let storageKey = "navigation-outbox-v1"
  /// Requests that keep failing for a reason other than being offline are
  /// given up on rather than retried forever.
  nonisolated static let maximumAttempts = 5

  private(set) var entries: [NavigationOutboxEntry]
  /// The request being sent right now, per machine. A newer change never
  /// merges into it -- its content is already on the wire -- so it queues
  /// behind it instead.
  var inFlight: Set<UUID> = []
  private let store: any PersistenceStore
  private let persistenceOwner = UUID()

  init(store: any PersistenceStore) {
    self.store = store
    entries =
      store.loadData(forKey: Self.storageKey)
      .flatMap { try? JSONDecoder().decode([NavigationOutboxEntry].self, from: $0) } ?? []
  }

  func entries(for machineId: String) -> [NavigationOutboxEntry] {
    entries.filter { $0.machineId == machineId }
  }

  /// Adds a request, replacing an unsent one with the same key in place so
  /// the order of different changes is kept. A removal replaces it at the
  /// end instead: taking the create's place would put it ahead of requests
  /// made since (a chat created in a project being deleted), which would
  /// then bring back what it removed.
  func enqueue(_ intent: NavigationIntent, machineId: String) {
    if let index = entries.firstIndex(where: {
      $0.machineId == machineId && $0.state == .pending && !inFlight.contains($0.id)
        && $0.intent.coalescingKey == intent.coalescingKey
    }) {
      if intent.isRemoval {
        entries.remove(at: index)
        entries.append(NavigationOutboxEntry(machineId: machineId, intent: intent))
        persist()
        return
      }
      entries[index].intent = intent
      entries[index].attempts = 0
    } else {
      entries.append(NavigationOutboxEntry(machineId: machineId, intent: intent))
    }
    persist()
  }

  func markAccepted(_ id: UUID, cursor: Int, at date: Date) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].state = .awaiting(cursor: cursor, acceptedAt: date)
    persist()
  }

  /// Counts a failed attempt; returns false once the entry has been dropped.
  @discardableResult
  func noteFailure(_ id: UUID) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
    entries[index].attempts += 1
    if entries[index].attempts >= Self.maximumAttempts {
      entries.remove(at: index)
      persist()
      return false
    }
    persist()
    return true
  }

  func remove(_ id: UUID) {
    entries.removeAll { $0.id == id }
    persist()
  }

  /// Retires accepted entries the cache now reflects: the cache has reached
  /// the cursor the server reported after accepting them, or a complete
  /// snapshot fetched after they were accepted has replaced the cache (which
  /// also covers a server whose event log was reset).
  /// Returns true if anything left.
  @discardableResult
  func retire(machineId: String, cursor: Int, snapshotRequestedAt: Date?) -> Bool {
    let before = entries.count
    entries.removeAll { entry in
      guard entry.machineId == machineId, case let .awaiting(target, acceptedAt) = entry.state else {
        return false
      }
      if cursor >= target { return true }
      if let snapshotRequestedAt, snapshotRequestedAt > acceptedAt { return true }
      return false
    }
    guard entries.count != before else { return false }
    persist()
    return true
  }

  /// Chats the server now lists no longer need their `expectSession` entry.
  @discardableResult
  func retireExpectedSessions(machineId: String, listed: Set<UUID>) -> Bool {
    let before = entries.count
    entries.removeAll { entry in
      entry.machineId == machineId && entry.intent.expectedSessionId.map(listed.contains) == true
    }
    guard entries.count != before else { return false }
    persist()
    return true
  }

  /// A machine this device no longer knows: its requests can never be sent.
  func removeAll(machineId: String) {
    let before = entries.count
    entries.removeAll { $0.machineId == machineId }
    if entries.count != before { persist() }
  }

  private func persist() {
    let snapshot = entries
    let store = store
    PersistenceEncoding.enqueueLatest(owner: persistenceOwner, key: Self.storageKey, delay: 0) {
      do {
        try store.saveData(JSONEncoder().encode(snapshot), forKey: Self.storageKey)
      } catch {
        Log.persistence.error("Failed to save the navigation outbox: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
