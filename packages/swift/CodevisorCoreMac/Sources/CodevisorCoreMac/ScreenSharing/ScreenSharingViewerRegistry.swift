import Foundation

@MainActor
protocol ScreenSharingViewerConnecting: AnyObject {
  func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent>
  func idle() async
}

@MainActor
final class ScreenSharingViewerRegistry {
  static let shared = ScreenSharingViewerRegistry()

  struct Key: Hashable {
    let machineId: String
    let displayId: String
  }

  @MainActor
  final class Share {
    let machineId: String
    let paneId: UUID
    let role: ScreenSharingViewerRole
    let runner: any ScreenSharingViewerConnecting
    private let registry: ScreenSharingViewerRegistry
    fileprivate var visible = false
    fileprivate var claimed = 0
    fileprivate var key: Key?
    fileprivate var subscription: UUID?
    fileprivate var continuation: AsyncStream<ScreenSharingViewerEvent>.Continuation?

    private var lastElsewhere: ScreenSharingViewerEvent?

    fileprivate func emit(_ event: ScreenSharingViewerEvent) {
      if case .elsewhere = event {
        guard event != lastElsewhere else { return }
        lastElsewhere = event
      } else {
        lastElsewhere = nil
      }
      continuation?.yield(event)
    }

    fileprivate func end() {
      let continuation = continuation
      key = nil
      subscription = nil
      lastElsewhere = nil
      self.continuation = nil
      continuation?.finish()
    }

    fileprivate init(
      registry: ScreenSharingViewerRegistry, machineId: String, paneId: UUID, role: ScreenSharingViewerRole,
      runner: any ScreenSharingViewerConnecting
    ) {
      self.registry = registry
      self.machineId = machineId
      self.paneId = paneId
      self.role = role
      self.runner = runner
    }

    func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent> {
      registry.subscribe(self, to: Key(machineId: machineId, displayId: display))
    }

    func setVisible(_ visible: Bool) { registry.setVisible(self, visible) }
    func claim() { registry.claim(self) }
    func retire() { registry.retire(paneId: paneId) }
    func liveStreams() -> AsyncStream<Void> { registry.liveStreams(machineId: machineId) }
  }

  private final class Entry {
    var sponsor: Share
    var subscribers: [Share] = []
    var active: Share?
    var endpoint: ScreenSharingViewerEndpoint?
    var ready = false
    var notice: String?
    var generation = 0
    var task: Task<Void, Never>?

    init(sponsor: Share) { self.sponsor = sponsor }
  }

  private var entries: [Key: Entry] = [:]
  private var draining: [Key: Task<Void, Never>] = [:]
  private var claims = 0
  private var liveWatchers: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

  func share(
    machineId: String, paneId: UUID, role: ScreenSharingViewerRole = .tab, runner: any ScreenSharingViewerConnecting
  ) -> Share {
    Share(registry: self, machineId: machineId, paneId: paneId, role: role, runner: runner)
  }

  fileprivate func liveStreams(machineId: String) -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let id = UUID()
    liveWatchers[machineId, default: [:]][id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.liveWatchers[machineId]?[id] = nil }
    }
    if isLive(machineId) { continuation.yield() }
    return stream
  }

  private func isLive(_ machineId: String) -> Bool {
    entries.contains { $0.key.machineId == machineId && $0.value.endpoint != nil }
  }

  private func announceLive(_ machineId: String) {
    for continuation in liveWatchers[machineId, default: [:]].values { continuation.yield() }
  }

  fileprivate func subscribe(_ share: Share, to key: Key) -> AsyncStream<ScreenSharingViewerEvent> {
    let (stream, continuation) = AsyncStream<ScreenSharingViewerEvent>.makeStream()
    unsubscribe(share)
    let subscription = UUID()
    share.key = key
    share.subscription = subscription
    share.continuation = continuation
    continuation.onTermination = { [weak self, weak share] _ in
      Task { @MainActor in
        guard let self, let share, share.subscription == subscription else { return }
        self.unsubscribe(share)
      }
    }
    let entry: Entry
    if let existing = entries[key] {
      entry = existing
    } else {
      entry = Entry(sponsor: share)
      entries[key] = entry
      run(entry, key: key, after: draining.removeValue(forKey: key))
    }
    entry.subscribers.append(share)
    if canTakeOver(share, in: entry) {
      claim(share, in: entry)
    } else {
      share.emit(.elsewhere(entry.endpoint))
    }
    return stream
  }

  private func unsubscribe(_ share: Share) {
    guard let key = share.key else { return }
    share.end()
    guard let entry = entries[key] else { return }
    entry.subscribers.removeAll { $0 === share }
    guard entry.subscribers.isEmpty else {
      if entry.active === share { handOff(from: share, in: entry) }
      return
    }
    entries[key] = nil
    entry.task?.cancel()
    let task = entry.task
    let runner = entry.sponsor.runner
    draining[key] = Task { @MainActor in
      await task?.value
      await runner.idle()
    }
  }

  fileprivate func setVisible(_ share: Share, _ visible: Bool) {
    share.visible = visible
    guard let key = share.key, let entry = entries[key] else { return }
    if visible {
      if canTakeOver(share, in: entry) { claim(share, in: entry) }
    } else if entry.active === share, let next = successor(in: entry, visibleOnly: true) {
      activate(next, in: entry)
    }
  }

  fileprivate func claim(_ share: Share) {
    guard share.role != .watcher, let key = share.key, let entry = entries[key] else { return }
    claim(share, in: entry)
  }

  private func canTakeOver(_ share: Share, in entry: Entry) -> Bool {
    guard share.role != .watcher else { return false }
    guard let active = entry.active else { return true }
    return share.visible && (!active.visible || share.role >= active.role)
  }

  private func handOff(from share: Share, in entry: Entry) {
    if let next = successor(in: entry) {
      activate(next, in: entry)
      return
    }
    entry.active = nil
    entry.endpoint?.relinquish()
  }

  fileprivate func retire(paneId: UUID) {
    for (key, entry) in entries where entry.sponsor.paneId == paneId {
      guard let next = entry.subscribers.first(where: { $0.paneId != paneId }) else { continue }
      let previous = entry.task
      let runner = entry.sponsor.runner
      previous?.cancel()
      entry.sponsor = next
      entry.endpoint = nil
      entry.ready = false
      entry.notice = nil
      for subscriber in entry.subscribers { subscriber.emit(.reconnecting) }
      run(
        entry, key: key,
        after: Task { @MainActor in
          await previous?.value
          await runner.idle()
        })
    }
  }

  private func claim(_ share: Share, in entry: Entry) {
    claims += 1
    share.claimed = claims
    activate(share, in: entry)
  }

  private func successor(in entry: Entry, visibleOnly: Bool = false) -> Share? {
    let others = entry.subscribers.filter { $0 !== entry.active && $0.role != .watcher }
    let visible = others.filter(\.visible)
    return (visible.isEmpty && !visibleOnly ? others : visible).max { ($0.role, $0.claimed) < ($1.role, $1.claimed) }
  }

  private func activate(_ share: Share, in entry: Entry) {
    guard entry.active !== share else { return }
    let previous = entry.active
    entry.active = share
    if previous != nil { entry.endpoint?.relinquish() }
    previous?.emit(.elsewhere(entry.endpoint))
    guard let endpoint = entry.endpoint else { return }
    share.emit(.opened(endpoint))
    if entry.ready { share.emit(.ready) }
    if let notice = entry.notice { share.emit(.hostNotice(notice)) }
  }

  private func run(_ entry: Entry, key: Key, after: Task<Void, Never>?) {
    entry.generation += 1
    let generation = entry.generation
    let runner = entry.sponsor.runner
    entry.task = Task { @MainActor [weak self] in
      await after?.value
      guard !Task.isCancelled else { return }
      for await event in runner.connect(key.displayId) {
        guard entry.generation == generation else { break }
        self?.deliver(event, to: entry)
      }
      guard let self, !Task.isCancelled, entry.generation == generation, self.entries[key] === entry else { return }
      self.entries[key] = nil
      self.draining[key] = Task { @MainActor in await runner.idle() }
      for subscriber in entry.subscribers { subscriber.end() }
    }
  }

  private func deliver(_ event: ScreenSharingViewerEvent, to entry: Entry) {
    switch event {
    case .opened(let endpoint):
      entry.endpoint = endpoint
      entry.ready = false
      entry.notice = nil
      entry.active?.emit(event)
      for subscriber in entry.subscribers where subscriber !== entry.active { subscriber.emit(.elsewhere(endpoint)) }
      announceLive(entry.sponsor.machineId)
    case .ready:
      entry.ready = true
      entry.active?.emit(event)
    case .hostNotice(let notice):
      entry.notice = notice
      entry.active?.emit(event)
    case .reconnecting, .ended:
      entry.endpoint = nil
      entry.ready = false
      entry.notice = nil
      for subscriber in entry.subscribers { subscriber.emit(event) }
    case .elsewhere:
      break
    }
  }
}
