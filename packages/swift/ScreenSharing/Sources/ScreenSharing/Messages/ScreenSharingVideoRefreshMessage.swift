import Foundation

package enum ScreenSharingVideoRefreshMessage: Sendable, Equatable {
  case keyframe
  case sourceIdle(latestTimestampNs: Int64)

  package func encoded() -> Data {
    switch self {
    case .keyframe:
      return Data([1])
    case .sourceIdle(let latestTimestampNs):
      var data = Data([2])
      withUnsafeBytes(of: latestTimestampNs.bigEndian) { data.append(contentsOf: $0) }
      return data
    }
  }

  package static func decode(_ data: Data) throws -> Self {
    let bytes = [UInt8](data)
    switch (bytes.first, bytes.count) {
    case (1, 1):
      return .keyframe
    case (2, 9):
      let value = bytes[1...].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      guard value <= UInt64(Int64.max) else { throw ScreenSharingError.invalid("Invalid idle notice.") }
      return .sourceIdle(latestTimestampNs: Int64(value))
    default:
      throw ScreenSharingError.invalid("Invalid video refresh request.")
    }
  }
}

package final class ScreenSharingRefreshSignal: @unchecked Sendable {
  package init() {}
  package struct Event: Sendable {
    let revision: UInt64
    package let needed: Bool
  }

  private let lock = NSLock()
  private var needed = false
  private var revision: UInt64 = 0
  private var generation: UInt64 = 0
  private var decoderReset = false
  private var closed = false
  private var callback: (@Sendable (Event) -> Void)?

  package func onChange(_ callback: @escaping @Sendable (Event) -> Void) {
    let pending: Event? = lock.withLock {
      guard !closed else { return nil }
      self.callback = callback
      return needed ? Event(revision: revision, needed: true) : nil
    }
    if let pending { callback(pending) }
  }
  package var keyframeGeneration: UInt64 { lock.withLock { generation } }
  package func request(resetDecoder: Bool = false) { change(to: true, resetDecoder: resetDecoder) }
  @discardableResult
  package func requestUnlessPending() -> Bool {
    let notification: ((@Sendable (Event) -> Void)?, Event)? = lock.withLock {
      guard !closed, !needed else { return nil }
      generation &+= 1
      needed = true
      revision &+= 1
      return (callback, Event(revision: revision, needed: true))
    }
    guard let (callback, event) = notification else { return false }
    callback?(event)
    return true
  }
  package func decodedKeyframe(generation: UInt64) { change(to: false, completedGeneration: generation) }
  package func consumeDecoderReset() -> Bool {
    lock.withLock {
      let result = decoderReset; decoderReset = false; return result
    }
  }
  package func close() {
    lock.withLock {
      closed = true; callback = nil
    }
  }

  private func change(to value: Bool, resetDecoder: Bool = false, completedGeneration: UInt64? = nil) {
    let notification: ((@Sendable (Event) -> Void), Event)? = lock.withLock {
      guard !closed else { return nil }
      if value {
        generation &+= 1
        decoderReset = decoderReset || resetDecoder
      } else if completedGeneration != generation || decoderReset {
        return nil
      }
      guard needed != value else { return nil }
      needed = value
      revision &+= 1
      guard let callback else { return nil }
      return (callback, Event(revision: revision, needed: value))
    }
    if let (callback, event) = notification { callback(event) }
  }
}

package final class ScreenSharingEncoderRefreshRequest: @unchecked Sendable {
  package init() {}
  private let lock = NSLock()
  private var pending = false
  package func request() { lock.withLock { pending = true } }
  package func consume() -> Bool {
    lock.withLock {
      let result = pending; pending = false; return result
    }
  }
}

package struct ScreenSharingRefreshRateLimit {
  package init() {}
  package static let intervalNs: Int64 = 100_000_000
  private var lastAllowed: Int64?

  package mutating func allow(nowNs: Int64) -> Bool {
    guard nowNs >= 0 else { return false }
    if let lastAllowed, nowNs < lastAllowed || nowNs - lastAllowed < Self.intervalNs { return false }
    lastAllowed = nowNs
    return true
  }
}

@MainActor
package final class ScreenSharingRefreshRequester {
  package static let repeatWhileArrivingNs: Int64 = 1_000_000_000
  private let send: () -> Bool
  private let available: () -> Bool
  private let receivedMediaBytes: ScreenSharingReceivedMediaBytes
  private let nowNs: @Sendable () -> Int64
  private let sleep: @Sendable (Duration) async throws -> Void
  private var task: Task<Void, Never>?
  private var revision: UInt64 = 0
  private var needed = false
  private var closed = false
  private var rateLimit = ScreenSharingRefreshRateLimit()
  private var lastSentNs: Int64?

  package init(
    available: @escaping () -> Bool, send: @escaping () -> Bool,
    receivedMediaBytes: @escaping ScreenSharingReceivedMediaBytes = { nil },
    nowNs: @escaping @Sendable () -> Int64 = { ScreenSharingMetrics.nowNs },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.available = available; self.send = send; self.receivedMediaBytes = receivedMediaBytes
    self.nowNs = nowNs; self.sleep = sleep
  }

  package func update(_ event: ScreenSharingRefreshSignal.Event) {
    guard !closed, event.revision > revision else { return }
    revision = event.revision
    needed = event.needed
    guard needed else { task?.cancel(); task = nil; return }
    wake()
    guard task == nil else { return }
    let sleep = sleep
    let receivedMediaBytes = receivedMediaBytes
    task = Task { @MainActor [weak self] in
      var media = ScreenSharingMediaArrival(receivedMediaBytes)
      await media.start()
      do {
        while !Task.isCancelled {
          try await sleep(.milliseconds(100))
          let mediaArrived = await media.arrivedSinceLastSample()
          guard !Task.isCancelled, let self, !self.closed, self.needed else { return }
          if !mediaArrived || self.sentLongAgo { self.wake() }
        }
      } catch {}
    }
  }

  package func wake() {
    guard !closed, needed, available() else { return }
    let now = nowNs()
    guard rateLimit.allow(nowNs: now), send() else { return }
    lastSentNs = now
  }

  private var sentLongAgo: Bool {
    guard let lastSentNs else { return true }
    return nowNs() - lastSentNs >= Self.repeatWhileArrivingNs
  }

  @discardableResult
  package func close() -> Task<Void, Never>? {
    closed = true
    needed = false
    let pending = task
    task = nil
    pending?.cancel()
    return pending
  }
}

package struct ScreenSharingRefreshFrameStore {
  package init() {}
  private var frame: ScreenSharingVideoFrame?
  private var lastCapturedNs: Int64?
  private var lastSubmittedNs: Int64?

  package mutating func capture(_ frame: ScreenSharingVideoFrame) -> ScreenSharingVideoFrame? {
    guard frame.timestampNs >= 0 else { return nil }
    if let lastCapturedNs, frame.timestampNs <= lastCapturedNs { return nil }
    guard let submission = nextSubmission(atLeast: frame.timestampNs) else { return nil }
    self.frame = frame
    lastCapturedNs = frame.timestampNs
    lastSubmittedNs = submission
    return ScreenSharingVideoFrame(
      pixelBuffer: frame.pixelBuffer, timestampNs: submission, sourceTimestampNs: frame.timestampNs)
  }

  package mutating func refresh(nowNs: Int64) -> ScreenSharingVideoFrame? {
    guard let frame, nowNs >= 0, let submission = nextSubmission(atLeast: nowNs) else { return nil }
    lastSubmittedNs = submission
    return ScreenSharingVideoFrame(
      pixelBuffer: frame.pixelBuffer, timestampNs: submission, sourceTimestampNs: frame.timestampNs)
  }

  package mutating func clear() { frame = nil }

  package var isHolding: Bool { frame != nil }

  private func nextSubmission(atLeast value: Int64) -> Int64? {
    guard let lastSubmittedNs else { return value }
    guard lastSubmittedNs < Int64.max else { return nil }
    return max(value, lastSubmittedNs + 1)
  }
}
