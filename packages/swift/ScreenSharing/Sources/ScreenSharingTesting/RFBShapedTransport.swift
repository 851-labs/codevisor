import Foundation
import ScreenSharing

/// Network conditions for L2 tests and `vnc-bench`
/// (docs/plans/vnc-validation.md). `bitsPerSecond` nil is an unlimited link.
public struct RFBNetworkProfile: Sendable, Equatable, Hashable {
  public var name: String
  public var roundTrip: Duration
  public var bitsPerSecond: Int?
  /// Each delivery moves by a seeded uniform offset in ±`jitter`, never reordering bytes.
  public var jitter: Duration

  public init(name: String, roundTrip: Duration, bitsPerSecond: Int? = nil, jitter: Duration = .zero) {
    self.name = name
    self.roundTrip = roundTrip
    self.bitsPerSecond = bitsPerSecond
    self.jitter = jitter
  }

  public static let lan = RFBNetworkProfile(name: "lan", roundTrip: .milliseconds(1))
  public static let wan40 = RFBNetworkProfile(
    name: "wan40", roundTrip: .milliseconds(40), bitsPerSecond: 100_000_000, jitter: .milliseconds(2))
  public static let wan150 = RFBNetworkProfile(
    name: "wan150", roundTrip: .milliseconds(150), bitsPerSecond: 50_000_000, jitter: .milliseconds(5))
  public static let constrained = RFBNetworkProfile(
    name: "constrained", roundTrip: .milliseconds(150), bitsPerSecond: 10_000_000, jitter: .milliseconds(5))
  public static let all: [RFBNetworkProfile] = [.lan, .wan40, .wan150, .constrained]

  public static func named(_ name: String) -> RFBNetworkProfile? { all.first { $0.name == name } }
}

/// When each send arrives on one direction of a shaped link: serialization at
/// the link's bandwidth (sends queue behind each other), half the round trip,
/// then seeded jitter clamped so deliveries stay in order. Pure, so the timing
/// rules are tested exactly; times are offsets from the link's start.
public struct RFBLinkSchedule: Sendable {
  public let profile: RFBNetworkProfile
  private var random: SplitMix64
  private var linkFree: Duration = .zero
  private var lastDelivery: Duration = .zero

  public init(profile: RFBNetworkProfile, seed: UInt64 = 1) {
    self.profile = profile
    random = SplitMix64(seed: seed)
  }

  public mutating func schedule(byteCount: Int, sentAt now: Duration) -> Duration {
    let start = max(now, linkFree)
    var serialization = Duration.zero
    if let bitsPerSecond = profile.bitsPerSecond, bitsPerSecond > 0 {
      serialization = .nanoseconds(Int64(byteCount) * 8 * 1_000_000_000 / Int64(bitsPerSecond))
    }
    linkFree = start + serialization
    var delivery = linkFree + profile.roundTrip / 2
    let spread = profile.jitter.nanoseconds
    if spread > 0 {
      delivery += .nanoseconds(Int64(random.next() % UInt64(2 * spread + 1)) - spread)
    }
    delivery = max(delivery, lastDelivery, now)
    lastDelivery = delivery
    return delivery
  }
}

extension Duration {
  fileprivate var nanoseconds: Int64 {
    let (seconds, attoseconds) = components
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
  }
}

/// An `RFBTransport` behind a shaped link: bytes read from `inner` reach the
/// caller, and bytes written reach `inner`, when `RFBLinkSchedule` says, as
/// measured on `clock`. Writes return at once (the kernel buffers a real
/// socket's too). Tests pass a `TestClock`; `vnc-bench` a `ContinuousClock`.
public final class RFBShapedTransport<C: Clock>: RFBTransport, @unchecked Sendable where C.Duration == Duration {
  private struct Delivery {
    let at: Duration
    /// Empty: the peer closed.
    let bytes: [UInt8]
  }

  private enum Head { case closed, empty, next(Delivery) }

  private let inner: any RFBTransport
  private let clock: C
  private let origin: C.Instant
  private let lock = NSLock()
  private var downlink: RFBLinkSchedule
  private var uplink: RFBLinkSchedule
  private var inbound: [Delivery] = []
  private var outbound: [Delivery] = []
  private var inbox: [UInt8] = []
  private var ended = false
  private var failure: (any Error)?
  private var readers: [CheckedContinuation<Void, Never>] = []
  private var inboundWaiter: CheckedContinuation<Void, Never>?
  private var outboundWaiter: CheckedContinuation<Void, Never>?
  private var tasks: [Task<Void, Never>] = []

  public var name: String { "\(inner.name) · shaped \(profile.name)" }
  private let profile: RFBNetworkProfile

  /// Reads waiting for bytes, for tests that must order a read before `close`.
  public var waitingReads: Int { lock.withLock { readers.count } }

  public init(_ inner: any RFBTransport, profile: RFBNetworkProfile, clock: C, seed: UInt64 = 1) {
    self.inner = inner
    self.profile = profile
    self.clock = clock
    origin = clock.now
    downlink = RFBLinkSchedule(profile: profile, seed: seed)
    uplink = RFBLinkSchedule(profile: profile, seed: seed &+ 1)
    tasks = [
      Task { [weak self] in await self?.receive() },
      Task { [weak self] in await self?.deliverInbound() },
      Task { [weak self] in await self?.deliverOutbound() },
    ]
  }

  deinit { close() }

  public func read(maximum: Int) async throws -> [UInt8] {
    while true {
      let outcome: Result<[UInt8], any Error>? = lock.withLock {
        if let failure { return .failure(failure) }
        if !inbox.isEmpty {
          let count = min(max(1, maximum), inbox.count)
          defer { inbox.removeFirst(count) }
          return .success(Array(inbox.prefix(count)))
        }
        return ended ? .success([]) : nil
      }
      if let outcome { return try outcome.get() }
      await withCheckedContinuation { continuation in
        let ready = lock.withLock {
          if failure != nil || !inbox.isEmpty || ended { return true }
          readers.append(continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    }
  }

  public func write(_ bytes: [UInt8]) async throws {
    let waiter: CheckedContinuation<Void, Never>? = try lock.withLock {
      if let failure { throw failure }
      outbound.append(Delivery(at: uplink.schedule(byteCount: bytes.count, sentAt: elapsed), bytes: bytes))
      defer { outboundWaiter = nil }
      return outboundWaiter
    }
    waiter?.resume()
  }

  public func close() {
    let (waiters, tasks) = lock.withLock {
      if failure == nil { failure = RFBError.connectionClosed }
      defer {
        readers = []
        inboundWaiter = nil
        outboundWaiter = nil
      }
      return (readers + [inboundWaiter, outboundWaiter].compactMap { $0 }, self.tasks)
    }
    for waiter in waiters { waiter.resume() }
    for task in tasks { task.cancel() }
    inner.close()
  }

  private var elapsed: Duration { origin.duration(to: clock.now) }

  // MARK: Pumps

  /// Reads `inner` as fast as it delivers and schedules each chunk.
  private func receive() async {
    while !Task.isCancelled {
      let bytes: [UInt8]
      do {
        bytes = try await inner.read(maximum: 64 << 10)
      } catch {
        fail(error)
        return
      }
      let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
        inbound.append(Delivery(at: downlink.schedule(byteCount: bytes.count, sentAt: elapsed), bytes: bytes))
        defer { inboundWaiter = nil }
        return inboundWaiter
      }
      waiter?.resume()
      if bytes.isEmpty { return }
    }
  }

  /// Moves each scheduled chunk into the inbox at its delivery time.
  private func deliverInbound() async {
    while let delivery = await next(\.inbound, waiter: \.inboundWaiter) {
      let readers: [CheckedContinuation<Void, Never>] = lock.withLock {
        if delivery.bytes.isEmpty { ended = true } else { inbox.append(contentsOf: delivery.bytes) }
        defer { self.readers = [] }
        return self.readers
      }
      for reader in readers { reader.resume() }
      if delivery.bytes.isEmpty { return }
    }
  }

  /// Writes each scheduled chunk to `inner` at its delivery time.
  private func deliverOutbound() async {
    while let delivery = await next(\.outbound, waiter: \.outboundWaiter) {
      do {
        try await inner.write(delivery.bytes)
      } catch {
        fail(error)
        return
      }
    }
  }

  /// The queue's head once it is due; nil when the transport closed.
  private func next(
    _ queue: ReferenceWritableKeyPath<RFBShapedTransport, [Delivery]>,
    waiter: ReferenceWritableKeyPath<RFBShapedTransport, CheckedContinuation<Void, Never>?>
  ) async -> Delivery? {
    while true {
      let head: Head = lock.withLock {
        if failure != nil { return .closed }
        return self[keyPath: queue].first.map(Head.next) ?? .empty
      }
      switch head {
      case .closed:
        return nil
      case .next(let delivery):
        let wait = delivery.at - elapsed
        if wait > .zero {
          do { try await clock.sleep(for: wait) } catch { return nil }
        }
        // One consumer per queue; producers only append, so the head is still this delivery.
        return lock.withLock { failure == nil ? self[keyPath: queue].removeFirst() : nil }
      case .empty:
        await withCheckedContinuation { continuation in
          let ready = lock.withLock {
            if failure != nil || !self[keyPath: queue].isEmpty { return true }
            self[keyPath: waiter] = continuation
            return false
          }
          if ready { continuation.resume() }
        }
      }
    }
  }

  private func fail(_ error: any Error) {
    let readers: [CheckedContinuation<Void, Never>] = lock.withLock {
      if failure == nil { failure = error }
      defer { self.readers = [] }
      return self.readers
    }
    for reader in readers { reader.resume() }
  }
}
