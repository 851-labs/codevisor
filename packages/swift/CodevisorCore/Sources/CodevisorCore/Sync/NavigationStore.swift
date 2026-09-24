import Foundation
import Observation

/// The one owner of navigation state on this device.
///
/// It holds the three stores -- cached server state per machine, the outbox,
/// and device layouts -- and rebuilds what the UI shows whenever any of them
/// changes. Server events only ever replace cached state; user actions only
/// ever add outbox requests or change layouts. That split is what keeps two
/// devices in step without merge rules: another device's change arrives as an
/// event and simply overwrites the cache, and this device's pending change
/// can't be lost because it lives in the outbox, not the cache.
@MainActor
@Observable
public final class NavigationStore {
  /// Not observed: views read the narrow per-workspace entries and the row
  /// lists instead, so a change to one workspace re-renders only its views.
  @ObservationIgnored public private(set) var projection = NavigationProjection.empty
  /// Which machines have a cache, and whether it is empty. What the launch
  /// screen and sync indicator depend on -- it changes only when a cache
  /// appears, disappears, or becomes empty or not, never on ordinary events.
  public private(set) var cacheSummary: [String: Bool] = [:]
  /// Advances on every rebuild. A wake-up signal for code that waits for the
  /// store to settle; views must not read it -- it changes on every event.
  public private(set) var revision: UInt64 = 0

  /// One observable entry per workspace; views observe these, not the store.
  @ObservationIgnored public let workspaceEntries = NavigationWorkspaces()
  @ObservationIgnored let layouts: DeviceLayoutStore
  @ObservationIgnored let executor: NavigationOutboxExecutor
  @ObservationIgnored private let caches: NavigationCacheStore
  @ObservationIgnored private let projector = NavigationProjector()
  @ObservationIgnored private let outbox: NavigationOutbox
  @ObservationIgnored private weak var projectList: ProjectListModel?
  @ObservationIgnored private weak var repository: ProjectedWorkspaceRepository?

  public init(
    store: any PersistenceStore,
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping () -> Date = Date.init
  ) {
    caches = NavigationCacheStore(store: store)
    outbox = NavigationOutbox(store: store)
    layouts = DeviceLayoutStore(store: store)
    executor = NavigationOutboxExecutor(outbox: outbox, clock: clock, now: now)
    executor.isDraftWorkspace = { [layouts] in layouts.draft(id: $0) != nil }
    executor.cachedCursor = { [weak self] in self?.caches.caches[$0]?.eventCursor ?? 0 }
    executor.onChange = { [weak self] machineId in
      guard let self else { return }
      self.retire(machineId: machineId, snapshotRequestedAt: nil)
      self.rebuild()
    }
  }

  /// Connects the models that render the projection. Called once at startup.
  func attach(projectList: ProjectListModel, repository: ProjectedWorkspaceRepository) {
    self.projectList = projectList
    self.repository = repository
    workspaceEntries.lookup = { [weak repository] in repository?.workspace(id: $0) }
    rebuild()
  }

  // MARK: - Server state

  public func hasCache(for machineId: String) -> Bool { cacheSummary[machineId] != nil }

  public func isCacheEmpty(for machineId: String) -> Bool { cacheSummary[machineId] ?? true }

  private func refreshCacheSummary() {
    let next = caches.caches.mapValues(\.isEmpty)
    if next != cacheSummary { cacheSummary = next }
  }

  public var cachedMachineIds: Set<String> { Set(caches.caches.keys) }

  func eventCursor(for machineId: String) -> Int? { caches.caches[machineId]?.eventCursor }

  /// Installs a complete snapshot from a machine. `requestedAt` is when the
  /// request left, which lets requests the server accepted before then leave
  /// the outbox even if the machine's event log was reset in between.
  ///
  /// A snapshot older than the cache is ignored unless `resetsStream` is set:
  /// events already applied would otherwise be lost, since the stream won't
  /// send them again. The machine's own connect sets it, because it restarts
  /// the event stream from the snapshot's cursor (which also recovers from a
  /// server whose event log was reset).
  public func replace(
    _ snapshot: ServerNavigationSnapshot, machineId: String, requestedAt: Date, resetsStream: Bool = true
  ) async {
    let cache = await MachineNavigationCache.build(machineId: machineId, snapshot: snapshot)
    if !resetsStream, let current = caches.caches[machineId], snapshot.eventCursor < current.eventCursor { return }
    caches.set(cache)
    layouts.prune(serverId: machineId, keeping: Set(snapshot.workspaces.compactMap { UUID(uuidString: $0.id) }))
    retire(machineId: machineId, snapshotRequestedAt: requestedAt)
    rebuild(origin: .snapshot)
  }

  /// Fetches a machine's current state now and installs it. Used where a
  /// screen needs the latest records (a project picker, pull to refresh).
  @discardableResult
  public func refresh(machineId: String, client: any CodevisorServerClienting) async -> ServerNavigationRefreshResult {
    let requestedAt = Date()
    do {
      let snapshot = try await client.navigationSnapshot()
      await replace(snapshot, machineId: machineId, requestedAt: requestedAt, resetsStream: false)
      return .committed
    } catch {
      return .failed(String(describing: error))
    }
  }

  /// Moves a machine's cache forward by one of its events. Returns false when
  /// there is no cache to move forward, meaning the caller needs a snapshot.
  public func apply(_ delta: ServerNavigationDelta, machineId: String) async -> Bool {
    guard let current = caches.caches[machineId] else { return false }
    guard let next = await current.applying(delta) else { return true }
    // Another event or snapshot landed while this one was being mapped; it
    // already carries at least this change, or will be followed by it.
    guard caches.caches[machineId]?.eventCursor == current.eventCursor else { return true }
    caches.set(next)
    retire(machineId: machineId, snapshotRequestedAt: nil)
    rebuild(origin: .liveEvent)
    return true
  }

  /// Forgets a machine that is no longer part of this account.
  public func forget(machineId: String) {
    caches.remove(machineId: machineId)
    outbox.removeAll(machineId: machineId)
    layouts.prune(serverId: machineId, keeping: [])
    rebuild()
  }

  // MARK: - User changes

  /// Records a change to server state, shows it immediately, and sends it.
  public func enqueue(
    _ intent: NavigationIntent, machineId: String,
    origin: SessionAttentionTransition.Origin = .snapshot
  ) {
    outbox.enqueue(intent, machineId: machineId)
    rebuild(origin: origin)
    executor.resume(machineId: machineId)
  }

  public var pendingIntents: [NavigationOutboxEntry] { outbox.entries }

  func addDraft(_ draft: WorkspaceDraft, layout: DeviceLayout) {
    layouts.addDraft(draft, layout: layout)
    rebuild()
  }

  func discardDraft(id: UUID) {
    layouts.remove(workspaceId: id)
    rebuild()
  }

  // MARK: - Rebuild

  private func retire(machineId: String, snapshotRequestedAt: Date?) {
    guard let cache = caches.caches[machineId] else { return }
    outbox.retire(machineId: machineId, cursor: cache.eventCursor, snapshotRequestedAt: snapshotRequestedAt)
    outbox.retireExpectedSessions(machineId: machineId, listed: Set(cache.sessions.map(\.id)))
  }

  /// Brings what navigation shows up to date with the three stores,
  /// recomputing only the machines and workspaces that changed.
  func rebuild(origin: SessionAttentionTransition.Origin = .snapshot) {
    let machineIds = Set(caches.caches.keys).union(outbox.entries.map(\.machineId))
      .union(layouts.drafts.map(\.serverId)).sorted()
    let result = projector.project(
      machineIds: machineIds, cache: { self.caches.caches[$0] }, cacheGeneration: { self.caches.generations[$0] },
      entries: { self.outbox.entries(for: $0) }, layouts: layouts)
    var promotedMachineIds = Set<String>()
    for draft in layouts.drafts where result.projection.workspacesById[draft.id]?.isServerSynced == true {
      layouts.promoteDraft(id: draft.id)
      promotedMachineIds.insert(draft.serverId)
    }
    projection = result.projection
    refreshCacheSummary()
    repository?.install(
      result.projection, changed: result.changedWorkspaceIds, removed: result.removedWorkspaceIds)
    projectList?.applyProjection(
      projects: result.projection.projects, sessions: result.projection.sessions, origin: origin)
    revision &+= 1
    // Requests held for a draft can go now that the server has it.
    for machineId in promotedMachineIds { executor.resume(machineId: machineId) }
  }
}
