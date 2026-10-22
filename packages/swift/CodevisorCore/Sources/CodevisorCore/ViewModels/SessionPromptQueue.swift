import Foundation
import Observation

@MainActor
@Observable
final class SessionPromptQueue {
  private static let promotionWindow: TimeInterval = 5
  private static let maxPendingPromotions = 32

  private(set) var items: [ServerPromptQueueItem] = []
  @ObservationIgnored private(set) var revision: UInt64 = 0
  @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
  @ObservationIgnored private var pendingPromotionIDs: [String: TimeInterval] = [:]
  @ObservationIgnored var onMessageQueued: ((UUID) -> Void)?
  @ObservationIgnored var onFailure: ((any Error) -> Void)?

  private let transport: ServerSessionTransport

  init(transport: ServerSessionTransport) {
    self.transport = transport
  }

  func apply(_ snapshot: [ServerPromptQueueItem]) {
    rememberRemovedItems(in: snapshot)
    items = snapshot
    for item in snapshot {
      if let queued = UUID(uuidString: item.id) { onMessageQueued?(queued) }
    }
    revision &+= 1
  }

  func refresh() async -> [ServerPromptQueueItem]? {
    guard let snapshot = try? await transport.promptQueue() else { return nil }
    apply(snapshot)
    return snapshot
  }

  func consumePromotion(id: String?) -> Bool {
    guard let id else { return false }
    let now = ProcessInfo.processInfo.systemUptime
    guard let deadline = pendingPromotionIDs.removeValue(forKey: id),
      deadline > now
    else { return false }
    return true
  }

  func update(id: String, text: String, attachments: [Attachment]? = nil) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || attachments?.isEmpty == false else { return false }
    do {
      _ = try await transport.updateQueuedPrompt(id: id, text: trimmed, attachments: attachments)
      return true
    } catch {
      onFailure?(error)
      return false
    }
  }

  func reorder(ids: [String]) async -> Bool {
    guard ids.count == Set(ids).count else { return false }
    let previous = items
    apply(Self.items(previous, orderedBy: ids))
    do {
      let reordered = try await transport.reorderQueuedPrompts(ids: ids)
      apply(reordered)
      return true
    } catch {
      apply(previous)
      onFailure?(error)
      return false
    }
  }

  func delete(id: String) async -> Bool {
    do {
      try await transport.deleteQueuedPrompt(id: id)
      return true
    } catch {
      onFailure?(error)
      return false
    }
  }

  func sendNow(id: String) async -> Bool {
    do {
      _ = try await transport.sendQueuedPromptNow(id: id)
      return true
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return false
    } catch {
      onFailure?(error)
      return false
    }
  }

  func scheduleLoad(keepingAlive owner: AnyObject) {
    let revision = revision
    loadTask = Task { @MainActor [weak self, weak owner] in
      guard let self, let owner else { return }
      await self.load(ifUnchangedSince: revision)
      if !Task.isCancelled {
        self.loadTask = nil
      }
      withExtendedLifetime(owner) {}
    }
  }

  func load() async {
    await load(ifUnchangedSince: revision)
  }

  func cancelLoad() {
    loadTask?.cancel()
    loadTask = nil
  }

  private func load(ifUnchangedSince loadRevision: UInt64) async {
    do {
      let snapshot = try await transport.promptQueue()
      guard !Task.isCancelled, loadRevision == revision else { return }
      items = snapshot
      revision &+= 1
    } catch {
      guard !isTaskCancellation(error) else { return }
      Log.session.error(
        "Failed to load prompt queue: \(String(describing: error), privacy: .public)"
      )
      guard loadRevision == revision else { return }
      items = []
      revision &+= 1
    }
  }

  private func rememberRemovedItems(in snapshot: [ServerPromptQueueItem]) {
    let now = ProcessInfo.processInfo.systemUptime
    pendingPromotionIDs = pendingPromotionIDs.filter { $0.value > now }
    let snapshotIDs = Set(snapshot.map(\.id))
    for item in items where !snapshotIDs.contains(item.id) {
      pendingPromotionIDs[item.id] = now + Self.promotionWindow
    }
    trimPendingPromotions()
  }

  private func trimPendingPromotions() {
    guard pendingPromotionIDs.count > Self.maxPendingPromotions else { return }
    let newest =
      pendingPromotionIDs
      .sorted { $0.value > $1.value }
      .prefix(Self.maxPendingPromotions)
      .map { ($0.key, $0.value) }
    pendingPromotionIDs = Dictionary(uniqueKeysWithValues: newest)
  }

  private nonisolated static func items(
    _ items: [ServerPromptQueueItem], orderedBy ids: [String]
  ) -> [ServerPromptQueueItem] {
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    let ordered = ids.compactMap { byID[$0] }
    return ordered + items.filter { !ids.contains($0.id) }
  }
}
