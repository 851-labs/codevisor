import Foundation
import os
@preconcurrency import WebRTC
import ScreenSharing

/// A bounded native ordered channel. Independent SCTP streams carry input and
/// clipboard transfers. Video uses its own RTP transport. Protocol code is
/// written against `ScreenSharingMessageChannel`; this is its WebRTC carrier.
///
/// Threading: the `RTCDataChannel` is confined to the channel's own serial queue. Every
/// `sendData`, `bufferedAmount`, `readyState` and `close` — each a call that waits for WebRTC's
/// network or signaling thread — runs there, never on the caller's thread. Received packets are
/// decoded on that queue too; a real-time consumer takes its messages there (`deliverOffMain`),
/// and only the rest reach `onMessage` on the main actor, in arrival order, as do availability
/// changes. `send` may be called from any thread: it admits the message against the send budget
/// at once (so a refusal is still reported synchronously) and hands it to the queue, which
/// preserves the order of sends.
nonisolated public final class ScreenSharingDataChannel<Message: Sendable>: ScreenSharingMessageChannel,
  @unchecked Sendable
{
  @MainActor public var onMessage: ((Message) -> Void)?
  @MainActor public var onAvailabilityChanged: ((Bool) -> Void)?
  /// Open and not closed, as last observed on the channel's queue.
  public var isAvailable: Bool { state.withLock { !$0.closed && $0.open } }
  let label: String
  private let queue: DispatchQueue
  /// The WebRTC object, touched only on `queue`; released there when the channel closes.
  private let carrier: Carrier
  private let receiver: ScreenSharingControlReceiver
  private let state = OSAllocatedUnfairLock(initialState: ChannelState())
  private let encode: @Sendable (Message) throws -> Data
  private let decode: @Sendable (Data) throws -> Message
  private let maximumBufferedBytes: Int
  private let reliable: Bool
  /// Main-actor only: the closed notice went out (exactly once).
  @MainActor private var publishedClose = false

  /// `limits` bounds one message and what may wait in either direction; the cursor channel
  /// carries images, the others small messages.
  init(
    connection: RTCPeerConnection, id: Int32, label: String, limits: ScreenSharingChannelLimits = .control,
    reliable: Bool = true,
    encode: @escaping @Sendable (Message) throws -> Data, decode: @escaping @Sendable (Data) throws -> Message
  ) throws {
    self.label = label
    self.encode = encode
    self.decode = decode
    maximumBufferedBytes = limits.bufferedBytes
    self.reliable = reliable
    queue = DispatchQueue(label: "codevisor.screen-sharing.channel.\(label)", qos: .userInteractive)
    receiver = ScreenSharingControlReceiver(limits: limits)
    let options = RTCDataChannelConfiguration()
    // Audio (851-2379) is unordered and never retransmitted: a late packet is worse than a lost one.
    options.isOrdered = reliable
    if !reliable { options.maxRetransmits = 0 }
    options.isNegotiated = true
    options.channelId = id
    options.protocol = label
    guard let channel = connection.dataChannel(forLabel: label, configuration: options) else {
      throw ScreenSharingError.unavailable("Cannot create the screen-sharing data channel.")
    }
    carrier = Carrier(channel)
    // WebRTC calls these on its own threads; each only schedules work on the channel's queue.
    let schedule: @Sendable (@escaping @Sendable (ScreenSharingDataChannel) -> Void) -> Void = {
      [weak self, queue] work in
      guard let channel = self else { return }
      queue.async { [weak channel] in if let channel { work(channel) } }
    }
    receiver.received = { schedule { $0.drainInbox() } }
    receiver.stateChanged = { schedule { $0.refreshState() } }
    receiver.bufferedAmountChanged = { schedule { $0.refreshBufferedAmount() } }
    channel.delegate = receiver
    // A state change before the delegate was set is picked up here.
    queue.async { [weak self] in self?.refreshState() }
  }

  /// Hands decoded messages to `take` on the channel's queue, in arrival order, before the main
  /// actor sees them; a message `take` returns true for never reaches `onMessage`. For a consumer
  /// that must not wait for main (the viewer's audio). Set it before the channel opens.
  public func deliverOffMain(_ take: (@Sendable (Message) -> Bool)?) { state.withLock { $0.offMain = take } }

  @discardableResult
  public func send(_ message: Message) -> Bool {
    guard isAvailable, let data = try? encode(message) else { return false }
    let size = data.count
    let admission: Admission = state.withLock { state in
      guard state.open, !state.closed else { return .refused }
      // What WebRTC still holds, what is on its way to it, and this message.
      guard state.bufferedBytes + UInt64(state.queuedBytes) + UInt64(size) <= UInt64(maximumBufferedBytes) else {
        // An unreliable channel sheds what doesn't fit instead of giving up.
        return reliable ? .overflow : .refused
      }
      state.queuedBytes += size
      return .accepted
    }
    switch admission {
    case .refused:
      return false
    case .overflow:
      fail()
      return false
    case .accepted:
      queue.async { [self] in
        let sent = carrier.channel?.sendData(RTCDataBuffer(data: data, isBinary: true)) ?? false
        let buffered = carrier.channel?.bufferedAmount ?? 0
        let closed = state.withLock { state in
          state.queuedBytes -= size
          state.bufferedBytes = buffered
          return state.closed
        }
        if !sent, !closed { fail() }
      }
      return true
    }
  }

  /// Terminal and idempotent. Publishes `false` to `onAvailabilityChanged` before returning, then
  /// drops both callbacks; the WebRTC channel closes on its queue without the caller waiting.
  @MainActor public func close() {
    if markClosed() { closeCarrier() }
    publishClosed()
  }

  /// Enqueues `group` behind everything the channel's queue was asked to do so far (its close
  /// included, once closed): the peer's teardown waits for it before closing the connection.
  func afterQueuedWork(in group: DispatchGroup) { queue.async(group: group) {} }

  // MARK: Channel queue

  private func refreshState() {
    let open = carrier.channel?.readyState == .open
    let buffered = carrier.channel?.bufferedAmount ?? 0
    let changed: Bool = state.withLock { state in
      state.bufferedBytes = buffered
      guard !state.closed, state.open != open else { return false }
      state.open = open
      return true
    }
    guard changed else { return }
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.publishedClose else { return }
        self.onAvailabilityChanged?(self.isAvailable)
      }
    }
  }

  private func refreshBufferedAmount() {
    guard let buffered = carrier.channel?.bufferedAmount else { return }
    state.withLock { $0.bufferedBytes = buffered }
  }

  /// One drain at a time: the schedule stays held until the main actor has delivered this batch,
  /// so a stalled main actor makes later packets wait in the bounded inbox (and overflow it)
  /// instead of piling up unbounded deliveries.
  private func drainInbox() {
    let (packets, failed) = receiver.drain()
    guard !failed else { fail(); return }
    let (closed, offMain) = state.withLock { ($0.closed, $0.offMain) }
    guard !closed else { return }
    var forMain: [Message] = []
    var undecodable = false
    for packet in packets {
      guard let message = try? decode(packet) else {
        undecodable = true
        break
      }
      if let offMain, offMain(message) { continue }
      forMain.append(message)
    }
    if forMain.isEmpty {
      if undecodable {
        fail()
      } else if receiver.finish() {
        queue.async { [weak self] in self?.drainInbox() }
      }
      return
    }
    // What decoded before a bad packet is still delivered, then the channel closes.
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        for message in forMain {
          guard !self.publishedClose, !self.state.withLock({ $0.closed }) else { break }
          self.onMessage?(message)
        }
        if undecodable {
          self.fail()
        } else if self.receiver.finish() {
          self.queue.async { [weak self] in self?.drainInbox() }
        }
      }
    }
  }

  // MARK: Teardown

  private enum Admission { case accepted, refused, overflow }

  /// Any thread: the channel gave up (a send budget overrun, a refused send, an overflowing or
  /// undecodable inbox). The main actor hears about it asynchronously, after what was queued.
  private func fail() {
    guard markClosed() else { return }
    closeCarrier()
    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.publishClosed() } }
  }

  /// True for the call that closed the channel.
  private func markClosed() -> Bool {
    let first = state.withLock { state in
      guard !state.closed else { return false }
      state.closed = true
      state.offMain = nil
      return true
    }
    if first { receiver.stop() }
    return first
  }

  private func closeCarrier() {
    let carrier = carrier
    queue.async {
      carrier.channel?.delegate = nil
      carrier.channel?.close()
      // The channel retains the peer's factory: its last release happens here, off the caller's thread.
      carrier.channel = nil
    }
  }

  @MainActor private func publishClosed() {
    guard !publishedClose else { return }
    publishedClose = true
    let changed = onAvailabilityChanged
    onAvailabilityChanged = nil
    onMessage = nil
    changed?(false)
  }

  deinit {
    // A channel dropped without `close()` still releases its WebRTC object on its own queue.
    let carrier = carrier
    queue.async { carrier.channel = nil }
  }

  /// The channel's lock-protected state.
  private struct ChannelState: Sendable {
    var open = false
    var closed = false
    /// Bytes `send` accepted that the queue has not yet handed to WebRTC.
    var queuedBytes = 0
    /// WebRTC's `bufferedAmount`, as last read on the queue.
    var bufferedBytes: UInt64 = 0
    var offMain: (@Sendable (Message) -> Bool)?
  }
}

/// Holds the `RTCDataChannel`; only the channel's queue reads or writes `channel`.
private final class Carrier: @unchecked Sendable {
  var channel: RTCDataChannel?
  init(_ channel: RTCDataChannel) { self.channel = channel }
}

/// WebRTC callbacks must not create an unbounded backlog. One scheduled drain admits at most
/// 256 messages / 64 KiB. Overflow closes the affected channel. Callbacks arrive on WebRTC's
/// threads and only schedule work; the hooks are set once, before the delegate is installed.
private final class ScreenSharingControlReceiver: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
  var received: (@Sendable () -> Void)?
  var stateChanged: (@Sendable () -> Void)?
  var bufferedAmountChanged: (@Sendable () -> Void)?
  private let lock = NSLock()
  private var inbox: ScreenSharingControlInbox

  init(limits: ScreenSharingChannelLimits) { inbox = ScreenSharingControlInbox(limits: limits) }

  func stop() { lock.withLock { inbox.stop() } }
  func drain() -> ([Data], Bool) { lock.withLock { inbox.drain() } }
  func finish() -> Bool { lock.withLock { inbox.finish() } }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) { stateChanged?() }
  func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) { bufferedAmountChanged?() }
  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    if lock.withLock({ inbox.enqueue(buffer.data) }) { received?() }
  }
}

/// How much one channel admits: a message, a drain's worth of messages, and unsent bytes.
public struct ScreenSharingChannelLimits: Sendable, Equatable {
  public var messageBytes: Int
  public var drainBytes: Int
  public var bufferedBytes: Int

  /// Control, clipboard and video refresh: small messages.
  public static let control = Self(
    messageBytes: ScreenSharingControlMessage.maximumBytes, drainBytes: 64 * 1024, bufferedBytes: 16 * 1024)
  /// The pointer (851-2377): a PNG now and then between tiny positions.
  public static let cursor = Self(
    messageBytes: ScreenSharingCursorMessage.maximumBytes, drainBytes: 256 * 1024, bufferedBytes: 128 * 1024)
}

/// Value state kept under the receiver's lock; independently exercises admission
/// limits without creating threads, media peers or event-loop timing in tests.
struct ScreenSharingControlInbox {
  let limits: ScreenSharingChannelLimits
  init(limits: ScreenSharingChannelLimits = .control) { self.limits = limits }
  private var packets: [Data] = []
  private var bytes = 0
  private var scheduled = false
  private var failed = false
  private var stopped = false

  /// True for the arrival that finds no drain outstanding: it must schedule one.
  mutating func enqueue(_ data: Data) -> Bool {
    guard !stopped else { return false }
    if packets.count >= 256 || data.count > limits.messageBytes || bytes + data.count > limits.drainBytes {
      failed = true
    } else if !failed {
      packets.append(data); bytes += data.count
    }
    guard !scheduled else { return false }
    scheduled = true
    return true
  }

  /// Takes the batch. The drain stays outstanding until `finish()`: arrivals meanwhile wait
  /// here, within the limits, rather than scheduling another.
  mutating func drain() -> ([Data], Bool) {
    let result = (packets, failed)
    packets = []; bytes = 0
    return result
  }

  /// The batch was delivered. True when more arrived meanwhile (the caller drains again, still
  /// outstanding); false releases the schedule for the next arrival.
  mutating func finish() -> Bool {
    guard packets.isEmpty, !failed else { return true }
    scheduled = false
    return false
  }

  mutating func stop() { stopped = true; packets = []; bytes = 0 }
}

public typealias ScreenSharingControlChannel = ScreenSharingDataChannel<ScreenSharingControlMessage>
public typealias ScreenSharingClipboardChannel = ScreenSharingDataChannel<ScreenSharingClipboardMessage>
public typealias ScreenSharingCursorChannel = ScreenSharingDataChannel<ScreenSharingCursorMessage>
public typealias ScreenSharingAudioChannel = ScreenSharingDataChannel<ScreenSharingAudioMessage>
public typealias ScreenSharingDisplayChannel = ScreenSharingDataChannel<ScreenSharingDisplayMessage>
public typealias ScreenSharingVideoFormatChannel = ScreenSharingDataChannel<ScreenSharingVideoFormatMessage>
public typealias ScreenSharingSimulatorChannel = ScreenSharingDataChannel<ScreenSharingSimulatorMessage>
public typealias ScreenSharingClipboardSharingChannel = ScreenSharingDataChannel<ScreenSharingClipboardSharingMessage>
