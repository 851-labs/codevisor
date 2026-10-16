import Foundation
import Observation
import ScreenSharing

@MainActor
@Observable
public final class ScreenSharingControlSession {
  public enum State: Equatable, Sendable {
    case idle
    case requesting
    case controlling
  }

  public private(set) var state: State = .idle
  public private(set) var notice: String?

  static let requestTimeout: Duration = .seconds(3)
  static let heartbeatInterval: Duration = .seconds(1)
  static let pendingLimit = 64

  @ObservationIgnored private let channel: any ScreenSharingMessageChannel<ScreenSharingControlMessage>
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let makeID: () -> UUID
  @ObservationIgnored private var requestID: UUID?
  @ObservationIgnored private var lease: UUID?
  @ObservationIgnored private var sequence: UInt64 = 0
  @ObservationIgnored private var pending: [ScreenSharingInputEvent] = []
  @ObservationIgnored private var timer: Task<Void, Never>?

  init(
    channel: any ScreenSharingMessageChannel<ScreenSharingControlMessage>, clock: any Clock<Duration>,
    makeID: @escaping () -> UUID = UUID.init
  ) {
    self.channel = channel
    self.clock = clock
    self.makeID = makeID
    channel.onMessage = { [weak self] in self?.receive($0) }
    channel.onAvailabilityChanged = { [weak self] available in
      guard !available, let self, self.state != .idle else { return }
      self.stop(notice: "The connection to the Mac was lost.")
    }
  }

  func send(_ events: [ScreenSharingInputEvent]) {
    guard !events.isEmpty else { return }
    switch state {
    case .controlling:
      deliver(events)
    case .requesting:
      enqueue(events)
    case .idle:
      enqueue(events)
      request()
    }
  }

  public func release() {
    if let lease { channel.send(.release(lease: lease)) }
    stop(notice: nil)
  }

  func close() {
    release()
    channel.onMessage = nil
    channel.onAvailabilityChanged = nil
  }

  func dismissNotice() { notice = nil }

  private func enqueue(_ events: [ScreenSharingInputEvent]) {
    pending.append(contentsOf: events)
    if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
  }

  private func request() {
    let id = makeID()
    requestID = id
    state = .requesting
    notice = nil
    guard channel.send(.request(id: id)) else {
      stop(notice: "The Mac isn't ready for control yet.")
      return
    }
    schedule(after: Self.requestTimeout) { [weak self] in
      guard let self, self.requestID == id, self.state == .requesting else { return }
      self.stop(notice: "The Mac didn't answer the request for control.")
    }
  }

  private func receive(_ message: ScreenSharingControlMessage) {
    switch message {
    case .grant(let request, let lease) where request == requestID && state == .requesting:
      self.lease = lease
      sequence = 0
      state = .controlling
      startHeartbeat(lease)
      let queued = pending
      pending = []
      deliver(queued)
    case .denied(let request, let reason) where request == requestID:
      stop(notice: reason)
    case .revoked(let lease, let reason) where lease == self.lease:
      stop(notice: reason)
    default:
      break
    }
  }

  private func deliver(_ events: [ScreenSharingInputEvent]) {
    guard let lease else { return }
    for event in events {
      sequence += 1
      guard channel.send(.input(lease: lease, sequence: sequence, event: event)) else {
        stop(notice: "The connection to the Mac was lost.")
        return
      }
    }
  }

  private func startHeartbeat(_ lease: UUID) {
    schedule(after: Self.heartbeatInterval) { [weak self] in
      guard let self, self.lease == lease, self.state == .controlling else { return }
      guard self.channel.send(.heartbeat(lease: lease)) else {
        self.stop(notice: "The connection to the Mac was lost.")
        return
      }
      self.startHeartbeat(lease)
    }
  }

  private func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) {
    timer?.cancel()
    timer = Task { [clock] in
      guard (try? await clock.sleep(for: delay)) != nil else { return }
      work()
    }
  }

  private func stop(notice: String?) {
    timer?.cancel()
    timer = nil
    requestID = nil
    lease = nil
    pending = []
    state = .idle
    self.notice = notice
  }
}
