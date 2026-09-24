import Foundation

/// Sends outbox requests to their machines, one at a time per machine and in
/// the order the user made them.
///
/// A request that fails because the machine can't be reached stays at the
/// front and is sent again when the machine is back (or after a backoff). A
/// request the server refuses is dropped: the cached server state is the
/// answer, and the UI falls back to it.
@MainActor
final class NavigationOutboxExecutor {
  enum Outcome: Equatable {
    case accepted
    case alreadyDone
    case rejected
    case retryLater(countsAsAttempt: Bool)
  }

  var clientProvider: (String) -> (any CodevisorServerClienting)? = { _ in nil }
  /// Only a machine whose navigation is current is sent to. Anything else is
  /// either offline or still catching up, and will resume the pump itself.
  var isMachineReady: (String) -> Bool = { _ in false }
  /// A workspace that exists only on this device. Its requests wait until
  /// opening its first chat creates it on the server.
  var isDraftWorkspace: (UUID) -> Bool = { _ in false }
  /// The cached event cursor of a machine, used when the server's current
  /// cursor can't be read after an accepted request.
  var cachedCursor: (String) -> Int = { _ in 0 }
  /// The outbox changed (an entry was accepted, dropped, or finished).
  var onChange: (String) -> Void = { _ in }

  private let outbox: NavigationOutbox
  private let clock: any Clock<Duration>
  private let now: () -> Date
  private var pumps: [String: Task<Void, Never>] = [:]
  private var retries: [String: Task<Void, Never>] = [:]
  private var failures: [String: Int] = [:]

  init(outbox: NavigationOutbox, clock: any Clock<Duration>, now: @escaping () -> Date = Date.init) {
    self.outbox = outbox
    self.clock = clock
    self.now = now
  }

  /// Starts sending a machine's waiting requests, if it isn't already.
  func resume(machineId: String) {
    guard pumps[machineId] == nil, isMachineReady(machineId) else { return }
    retries.removeValue(forKey: machineId)?.cancel()
    pumps[machineId] = Task { [weak self] in
      await self?.pump(machineId: machineId)
      self?.pumps[machineId] = nil
    }
  }

  func resumeAll() {
    for machineId in Set(outbox.entries.map(\.machineId)) { resume(machineId: machineId) }
  }

  /// Waits for a machine's pump to go idle (tests and pull to refresh).
  func idle(machineId: String) async {
    await pumps[machineId]?.value
  }

  func cancelAll() {
    for task in pumps.values { task.cancel() }
    for task in retries.values { task.cancel() }
    pumps.removeAll()
    retries.removeAll()
  }

  private func nextEntry(machineId: String) -> NavigationOutboxEntry? {
    outbox.entries.first { entry in
      entry.machineId == machineId && entry.state == .pending && !entry.intent.isSentElsewhere
        && !(entry.intent.workspaceId.map(isDraftWorkspace) ?? false)
    }
  }

  private func pump(machineId: String) async {
    while !Task.isCancelled, isMachineReady(machineId), let entry = nextEntry(machineId: machineId),
      let client = clientProvider(machineId)
    {
      outbox.inFlight.insert(entry.id)
      let outcome = await send(entry, with: client)
      outbox.inFlight.remove(entry.id)
      guard !Task.isCancelled else { return }
      switch outcome {
      case .accepted:
        failures[machineId] = nil
        let cursor = (try? await client.latestShellEventCursor()) ?? cachedCursor(machineId) + 1
        outbox.markAccepted(entry.id, cursor: cursor, at: now())
      case .alreadyDone, .rejected:
        outbox.remove(entry.id)
      case let .retryLater(countsAsAttempt):
        if countsAsAttempt, !outbox.noteFailure(entry.id) {
          onChange(machineId)
          continue
        }
        onChange(machineId)
        scheduleRetry(machineId: machineId)
        return
      }
      onChange(machineId)
    }
  }

  private func send(_ entry: NavigationOutboxEntry, with client: any CodevisorServerClienting) async -> Outcome {
    do {
      try await entry.intent.perform(with: client)
      return .accepted
    } catch {
      let outcome = Self.classify(error, isRemoval: entry.intent.isRemoval)
      if outcome == .rejected {
        Log.sync.error(
          "The server refused \(entry.intent.coalescingKey, privacy: .public); showing its state: \(String(describing: error), privacy: .public)"
        )
      }
      return outcome
    }
  }

  static func classify(_ error: any Error, isRemoval: Bool) -> Outcome {
    guard case let CodevisorServerClientError.httpStatus(status, _) = error else {
      // Transport failures mean the machine isn't reachable right now. They
      // never use up an attempt: the request waits for the machine instead.
      if error is URLError || error is CancellationError { return .retryLater(countsAsAttempt: false) }
      return .retryLater(countsAsAttempt: true)
    }
    switch status {
    case 404 where isRemoval: return .alreadyDone
    case 408, 429: return .retryLater(countsAsAttempt: false)
    case 400..<500: return .rejected
    default: return .retryLater(countsAsAttempt: true)
    }
  }

  private func scheduleRetry(machineId: String) {
    guard retries[machineId] == nil else { return }
    let count = (failures[machineId] ?? 0) + 1
    failures[machineId] = count
    let delay = Duration.seconds(min(60, 1 << min(count, 6)))
    let clock = clock
    retries[machineId] = Task { [weak self] in
      try? await clock.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.retries[machineId] = nil
      self.resume(machineId: machineId)
    }
  }
}
