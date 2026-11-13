import Foundation
import ScreenSharingV2

@MainActor
protocol ScreenSharingViewerConnecting: AnyObject {
  func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent>
  func idle() async
}

@MainActor
final class ScreenSharingViewerRegistry {
  static let shared = ScreenSharingViewerRegistry()

  @MainActor
  final class Share {
    let machineId: String
    let paneId: UUID
    let role: ScreenSharingViewerRole
    let runner: any ScreenSharingViewerConnecting
    private let registry: ScreenSharingViewerRegistry
    fileprivate var visible = false
    fileprivate var claimed = 0
    fileprivate var heardStream = 0
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

    func connect(_ display: String, switching: Bool = false) -> AsyncStream<ScreenSharingViewerEvent> {
      registry.subscribe(self, to: display, switching: switching)
    }

    func setVisible(_ visible: Bool) { registry.setVisible(self, visible) }
    func claim() { registry.claim(self) }
    func retire() { registry.retire(self) }
    func liveStreams() -> AsyncStream<Void> { registry.liveStreams(for: self) }
  }

  private final class Entry {
    let machineId: String
    var sponsor: Share
    var display: String
    var subscribers: [Share] = []
    var active: Share?
    var endpoint: ScreenSharingViewerEndpoint?
    var stream = 0
    var ready = false
    var notice: String?
    var progress: ScreenSharingConnectStage?
    var generation = 0
    var task: Task<Void, Never>?

    init(sponsor: Share, display: String) {
      machineId = sponsor.machineId
      self.sponsor = sponsor
      self.display = display
    }
  }

  private typealias LiveWatcher = (share: Share, continuation: AsyncStream<Void>.Continuation)

  private var entries: [String: Entry] = [:]
  private var draining: [String: Task<Void, Never>] = [:]
  private var claims = 0
  private var streams = 0
  private var liveWatchers: [String: [UUID: LiveWatcher]] = [:]

  func share(
    machineId: String, paneId: UUID, role: ScreenSharingViewerRole = .tab, runner: any ScreenSharingViewerConnecting
  ) -> Share {
    Share(registry: self, machineId: machineId, paneId: paneId, role: role, runner: runner)
  }

  fileprivate func liveStreams(for share: Share) -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let id = UUID()
    let machineId = share.machineId
    liveWatchers[machineId, default: [:]][id] = (share, continuation)
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.liveWatchers[machineId]?[id] = nil }
    }
    announceLive(to: (share, continuation))
    return stream
  }

  private func announceLive(to watcher: LiveWatcher) {
    guard let entry = entries[watcher.share.machineId], entry.endpoint != nil else { return }
    guard entry.stream > watcher.share.heardStream, case .enqueued = watcher.continuation.yield() else { return }
    watcher.share.heardStream = entry.stream
  }

  fileprivate func subscribe(
    _ share: Share, to display: String, switching: Bool
  ) -> AsyncStream<ScreenSharingViewerEvent> {
    let (stream, continuation) = AsyncStream<ScreenSharingViewerEvent>.makeStream()
    unsubscribe(share)
    let subscription = UUID()
    share.subscription = subscription
    share.continuation = continuation
    continuation.onTermination = { [weak self, weak share] _ in
      Task { @MainActor in
        guard let self, let share, share.subscription == subscription else { return }
        self.unsubscribe(share)
      }
    }
    let entry = connection(for: share, on: display, switching: switching)
    entry.subscribers.append(share)
    updateAudio(entry)
    if canTakeOver(share, in: entry) {
      claim(share, in: entry)
    } else {
      share.emit(.elsewhere(entry.endpoint))
    }
    return stream
  }

  private func connection(for share: Share, on display: String, switching: Bool) -> Entry {
    if let existing = entries[share.machineId] {
      if switching, existing.display != display { reconnect(existing, under: existing.sponsor, on: display) }
      return existing
    }
    let entry = Entry(sponsor: share, display: display)
    entries[share.machineId] = entry
    run(entry, after: draining.removeValue(forKey: share.machineId))
    return entry
  }

  private func unsubscribe(_ share: Share) {
    guard share.subscription != nil else { return }
    share.end()
    guard let entry = entries[share.machineId] else { return }
    entry.subscribers.removeAll { $0 === share }
    updateAudio(entry)
    guard entry.subscribers.isEmpty else {
      if entry.active === share { handOff(from: share, in: entry) }
      return
    }
    entries[entry.machineId] = nil
    entry.task?.cancel()
    let task = entry.task
    let runner = entry.sponsor.runner
    draining[entry.machineId] = Task { @MainActor in
      await task?.value
      await runner.idle()
    }
  }

  fileprivate func setVisible(_ share: Share, _ visible: Bool) {
    share.visible = visible
    guard share.subscription != nil, let entry = entries[share.machineId] else { return }
    if visible {
      if canTakeOver(share, in: entry) { claim(share, in: entry) }
    } else if entry.active === share, let next = successor(in: entry, visibleOnly: true) {
      activate(next, in: entry)
    }
  }

  fileprivate func claim(_ share: Share) {
    guard share.role != .watcher, share.subscription != nil, let entry = entries[share.machineId] else { return }
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

  fileprivate func retire(_ share: Share) {
    guard let entry = entries[share.machineId], entry.sponsor.paneId == share.paneId else { return }
    guard let next = entry.subscribers.first(where: { $0.paneId != share.paneId }) else { return }
    reconnect(entry, under: next, on: entry.display)
  }

  private func reconnect(_ entry: Entry, under sponsor: Share, on display: String) {
    let previous = entry.task
    let runner = entry.sponsor.runner
    previous?.cancel()
    entry.sponsor = sponsor
    entry.display = display
    entry.endpoint = nil
    entry.ready = false
    entry.notice = nil
    entry.progress = nil
    for subscriber in entry.subscribers { subscriber.emit(.reconnecting) }
    run(
      entry,
      after: Task { @MainActor in
        await previous?.value
        await runner.idle()
      })
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
    if let progress = entry.progress, !entry.ready { share.emit(.progress(progress)) }
  }

  private func updateAudio(_ entry: Entry) {
    entry.endpoint?.audio?.audible = entry.subscribers.contains { $0.role != .watcher }
  }

  private func run(_ entry: Entry, after: Task<Void, Never>?) {
    entry.generation += 1
    let generation = entry.generation
    let runner = entry.sponsor.runner
    let display = entry.display
    let machineId = entry.machineId
    entry.task = Task { @MainActor [weak self] in
      await after?.value
      guard !Task.isCancelled else { return }
      for await event in runner.connect(display) {
        guard entry.generation == generation else { break }
        self?.deliver(event, to: entry)
      }
      guard let self, !Task.isCancelled, entry.generation == generation, self.entries[machineId] === entry else {
        return
      }
      self.entries[machineId] = nil
      self.draining[machineId] = Task { @MainActor in await runner.idle() }
      for subscriber in entry.subscribers { subscriber.end() }
    }
  }

  private func deliver(_ event: ScreenSharingViewerEvent, to entry: Entry) {
    switch event {
    case .opened(let endpoint):
      entry.endpoint = endpoint
      entry.ready = false
      entry.notice = nil
      updateAudio(entry)
      entry.active?.emit(event)
      for subscriber in entry.subscribers where subscriber !== entry.active { subscriber.emit(.elsewhere(endpoint)) }
      streams += 1
      entry.stream = streams
      for watcher in liveWatchers[entry.machineId, default: [:]].values { announceLive(to: watcher) }
    case .ready:
      entry.ready = true
      entry.progress = nil
      entry.active?.emit(event)
    case .progress(let stage):
      entry.progress = stage
      entry.active?.emit(event)
    case .hostNotice(let notice):
      entry.notice = notice
      entry.active?.emit(event)
    case .reconnecting, .ended:
      entry.endpoint = nil
      entry.ready = false
      entry.notice = nil
      entry.progress = nil
      for subscriber in entry.subscribers { subscriber.emit(event) }
    case .elsewhere:
      break
    }
  }
}
