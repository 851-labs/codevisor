import Foundation
import Observation

@MainActor
@Observable
public final class NavigationStore {
  @ObservationIgnored public private(set) var projection = NavigationProjection.empty
  public private(set) var cacheSummary: [String: Bool] = [:]
  public private(set) var revision: UInt64 = 0

  @ObservationIgnored public let workspaceEntries = NavigationWorkspaces()
  @ObservationIgnored let layouts: DeviceLayoutStore
  @ObservationIgnored let executor: NavigationOutboxExecutor
  @ObservationIgnored private let caches: NavigationCacheStore
  @ObservationIgnored private let projector = NavigationProjector()
  @ObservationIgnored private let outbox: NavigationOutbox
  @ObservationIgnored private weak var projectList: ProjectListModel?
  @ObservationIgnored private weak var repository: ProjectedWorkspaceRepository?
  @ObservationIgnored private var cacheGenerations: [String: UInt64] = [:]

  public init(
    store: any PersistenceStore,
    launchSnapshot: ClientLaunchSnapshot? = nil,
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping () -> Date = Date.init
  ) {
    caches = NavigationCacheStore(store: store, preloaded: launchSnapshot?.navigationCaches)
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

  func attach(projectList: ProjectListModel, repository: ProjectedWorkspaceRepository) {
    self.projectList = projectList
    self.repository = repository
    workspaceEntries.lookup = { [weak repository] in repository?.workspace(id: $0) }
    rebuild()
  }

  public func hasCache(for machineId: String) -> Bool { cacheSummary[machineId] != nil }

  public func isCacheEmpty(for machineId: String) -> Bool { cacheSummary[machineId] ?? true }

  private func refreshCacheSummary() {
    let next = caches.caches.mapValues(\.isEmpty)
    if next != cacheSummary { cacheSummary = next }
  }

  public var cachedMachineIds: Set<String> { Set(caches.caches.keys) }

  func eventCursor(for machineId: String) -> Int? { caches.caches[machineId]?.eventCursor }

  @discardableResult
  public func replace(
    _ snapshot: ServerNavigationSnapshot, machineId: String, requestedAt: Date, resetsStream: Bool = true
  ) async -> Bool {
    guard !Task.isCancelled else { return false }
    if resetsStream {
      cacheGenerations[machineId, default: 0] &+= 1
    }
    let generation = cacheGenerations[machineId, default: 0]
    let cache = await MachineNavigationCache.build(machineId: machineId, snapshot: snapshot)
    guard !Task.isCancelled, cacheGenerations[machineId, default: 0] == generation else { return false }
    if !resetsStream, let current = caches.caches[machineId], snapshot.eventCursor < current.eventCursor {
      return false
    }
    caches.set(cache)
    layouts.prune(serverId: machineId, keeping: Set(snapshot.workspaces.compactMap { UUID(uuidString: $0.id) }))
    retire(machineId: machineId, snapshotRequestedAt: requestedAt)
    rebuild(origin: .snapshot)
    return true
  }

  @discardableResult
  public func refresh(machineId: String, client: any CodevisorServerClienting) async -> ServerNavigationRefreshResult {
    let requestedAt = Date()
    let generation = cacheGenerations[machineId, default: 0]
    do {
      let snapshot = try await client.navigationSnapshot()
      guard !Task.isCancelled, cacheGenerations[machineId, default: 0] == generation else { return .superseded }
      return await replace(snapshot, machineId: machineId, requestedAt: requestedAt, resetsStream: false)
        ? .committed : .superseded
    } catch {
      return .failed(String(describing: error))
    }
  }

  public func apply(_ delta: ServerNavigationDelta, machineId: String) async -> Bool {
    let generation = cacheGenerations[machineId, default: 0]
    while !Task.isCancelled, cacheGenerations[machineId, default: 0] == generation {
      guard let current = caches.caches[machineId] else { return false }
      guard let next = await current.applying(delta) else { return true }
      guard !Task.isCancelled, cacheGenerations[machineId, default: 0] == generation else { return false }
      guard caches.caches[machineId]?.eventCursor == current.eventCursor else { continue }
      caches.set(next)
      retire(machineId: machineId, snapshotRequestedAt: nil)
      rebuild(origin: .liveEvent)
      return true
    }
    return false
  }

  public func forget(machineId: String) {
    cacheGenerations[machineId, default: 0] &+= 1
    caches.remove(machineId: machineId)
    outbox.removeAll(machineId: machineId)
    layouts.prune(serverId: machineId, keeping: [])
    rebuild()
  }

  public func enqueue(
    _ intent: NavigationIntent, machineId: String,
    origin: SessionAttentionTransition.Origin = .snapshot
  ) {
    outbox.enqueue(intent, machineId: machineId)
    rebuild(origin: origin)
    executor.resume(machineId: machineId)
  }

  public var pendingIntents: [NavigationOutboxEntry] { outbox.entries }

  func publishTabOrder(of workspace: Workspace) {
    guard workspace.isServerSynced else { return }
    var records = NavigationRecords(caches.caches[workspace.serverId])
    NavigationOverlay.apply(outbox.entries(for: workspace.serverId), to: &records)
    let positions = SharedTabOrder.positions(of: records.panes, workspaceId: workspace.id)
    let moves = SharedTabOrder.moves(for: workspace.centerTabs, positions: positions)
    guard !moves.isEmpty else { return }
    for move in moves {
      outbox.enqueue(
        .movePane(paneId: move.paneId, workspaceId: workspace.id, position: move.position),
        machineId: workspace.serverId)
    }
    rebuild()
    executor.resume(machineId: workspace.serverId)
  }

  func addDraft(_ draft: WorkspaceDraft, layout: DeviceLayout) {
    layouts.addDraft(draft, layout: layout)
    rebuild()
  }

  func discardDraft(id: UUID) {
    layouts.remove(workspaceId: id)
    rebuild()
  }

  private func retire(machineId: String, snapshotRequestedAt: Date?) {
    guard let cache = caches.caches[machineId] else { return }
    outbox.retire(machineId: machineId, cursor: cache.eventCursor, snapshotRequestedAt: snapshotRequestedAt)
    outbox.retireExpectedSessions(machineId: machineId, listed: Set(cache.sessions.map(\.id)))
  }

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
    for machineId in promotedMachineIds { executor.resume(machineId: machineId) }
  }
}
