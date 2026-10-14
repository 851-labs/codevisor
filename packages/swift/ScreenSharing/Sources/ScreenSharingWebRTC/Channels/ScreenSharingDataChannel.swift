import Foundation
import os
@preconcurrency import WebRTC
import ScreenSharing

nonisolated public final class ScreenSharingDataChannel<Message: Sendable>: ScreenSharingMessageChannel,
  @unchecked Sendable
{
  @MainActor public var onMessage: ((Message) -> Void)?
  @MainActor public var onAvailabilityChanged: ((Bool) -> Void)?
  public var isAvailable: Bool { state.withLock { !$0.closed && $0.open } }
  let label: String
  private let queue: DispatchQueue
  private let carrier: Carrier
  private let receiver: ScreenSharingControlReceiver
  private let state = OSAllocatedUnfairLock(initialState: ChannelState())
  private let encode: @Sendable (Message) throws -> Data
  private let decode: @Sendable (Data) throws -> Message
  private let maximumBufferedBytes: Int
  private let reliable: Bool
  @MainActor private var publishedClose = false

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
    options.isOrdered = reliable
    if !reliable { options.maxRetransmits = 0 }
    options.isNegotiated = true
    options.channelId = id
    options.protocol = label
    guard let channel = connection.dataChannel(forLabel: label, configuration: options) else {
      throw ScreenSharingError.unavailable("Cannot create the screen-sharing data channel.")
    }
    carrier = Carrier(channel)
    let schedule: @Sendable (@escaping @Sendable (ScreenSharingDataChannel) -> Void) -> Void = {
      [weak self, queue] work in
      guard let channel = self else { return }
      queue.async { [weak channel] in if let channel { work(channel) } }
    }
    receiver.received = { schedule { $0.drainInbox() } }
    receiver.stateChanged = { schedule { $0.refreshState() } }
    receiver.bufferedAmountChanged = { schedule { $0.refreshBufferedAmount() } }
    channel.delegate = receiver
    queue.async { [weak self] in self?.refreshState() }
  }

  public func deliverOffMain(_ take: (@Sendable (Message) -> Bool)?) { state.withLock { $0.offMain = take } }

  @discardableResult
  public func send(_ message: Message) -> Bool {
    guard isAvailable, let data = try? encode(message) else { return false }
    let size = data.count
    let admission: Admission = state.withLock { state in
      guard state.open, !state.closed else { return .refused }
      guard state.bufferedBytes + UInt64(state.queuedBytes) + UInt64(size) <= UInt64(maximumBufferedBytes) else {
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

  @MainActor public func close() {
    if markClosed() { closeCarrier() }
    publishClosed()
  }

  func afterQueuedWork(in group: DispatchGroup) { queue.async(group: group) {} }

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

  private enum Admission { case accepted, refused, overflow }

  private func fail() {
    guard markClosed() else { return }
    closeCarrier()
    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.publishClosed() } }
  }

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
    let carrier = carrier
    queue.async { carrier.channel = nil }
  }

  private struct ChannelState: Sendable {
    var open = false
    var closed = false
    var queuedBytes = 0
    var bufferedBytes: UInt64 = 0
    var offMain: (@Sendable (Message) -> Bool)?
  }
}

private final class Carrier: @unchecked Sendable {
  var channel: RTCDataChannel?
  init(_ channel: RTCDataChannel) { self.channel = channel }
}

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

public struct ScreenSharingChannelLimits: Sendable, Equatable {
  public var messageBytes: Int
  public var drainBytes: Int
  public var bufferedBytes: Int

  public static let control = Self(
    messageBytes: ScreenSharingControlMessage.maximumBytes, drainBytes: 64 * 1024, bufferedBytes: 16 * 1024)
  public static let cursor = Self(
    messageBytes: ScreenSharingCursorMessage.maximumBytes, drainBytes: 256 * 1024, bufferedBytes: 128 * 1024)
}

struct ScreenSharingControlInbox {
  let limits: ScreenSharingChannelLimits
  init(limits: ScreenSharingChannelLimits = .control) { self.limits = limits }
  private var packets: [Data] = []
  private var bytes = 0
  private var scheduled = false
  private var failed = false
  private var stopped = false

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

  mutating func drain() -> ([Data], Bool) {
    let result = (packets, failed)
    packets = []; bytes = 0
    return result
  }

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
