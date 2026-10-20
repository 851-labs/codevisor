import Foundation

public struct NavigationOutboxEntry: Codable, Equatable, Sendable, Identifiable {
  public enum State: Codable, Equatable, Sendable {
    case pending
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

@MainActor
final class NavigationOutbox {
  nonisolated static let storageKey = "navigation-outbox-v1"
  nonisolated static let maximumAttempts = 5

  private(set) var entries: [NavigationOutboxEntry]
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

  @discardableResult
  func retireListedProjects(machineId: String, listed: Set<UUID>) -> Bool {
    let before = entries.count
    entries.removeAll { entry in
      guard entry.machineId == machineId, case .awaiting = entry.state else { return false }
      return entry.intent.upsertedProjectId.map(listed.contains) == true
    }
    guard entries.count != before else { return false }
    persist()
    return true
  }

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
