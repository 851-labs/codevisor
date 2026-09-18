import Foundation
@preconcurrency import WebRTC
import ScreenSharing

/// A bounded native ordered channel. Independent SCTP streams carry input and
/// clipboard transfers. Video uses its own RTP transport. Protocol code is
/// written against `ScreenSharingMessageChannel`; this is its WebRTC carrier.
@MainActor
public final class ScreenSharingDataChannel<Message: Sendable>: ScreenSharingMessageChannel {
  public var onMessage: ((Message) -> Void)?
  public var onAvailabilityChanged: ((Bool) -> Void)?
  public var isAvailable: Bool { !closed && channel.readyState == .open }
  private let channel: RTCDataChannel
  private let receiver = ScreenSharingControlReceiver()
  private var closed = false
  private let encode: (Message) throws -> Data

  init(
    connection: RTCPeerConnection, id: Int32, label: String,
    encode: @escaping (Message) throws -> Data, decode: @escaping (Data) throws -> Message
  ) throws {
    self.encode = encode
    let options = RTCDataChannelConfiguration()
    options.isOrdered = true
    options.isNegotiated = true
    options.channelId = id
    options.protocol = label
    guard let channel = connection.dataChannel(forLabel: label, configuration: options) else {
      throw ScreenSharingError.unavailable("Cannot create the screen-sharing data channel.")
    }
    self.channel = channel
    receiver.deliver = { [weak self] packets, failed in
      guard let self, !self.closed else { return }
      if failed { self.close(); return }
      for packet in packets {
        guard !self.closed else { return }
        do { self.onMessage?(try decode(packet)) } catch { self.close(); return }
      }
    }
    receiver.stateChanged = { [weak self] in
      guard let self, !self.closed else { return }
      self.onAvailabilityChanged?(self.isAvailable)
    }
    channel.delegate = receiver
  }

  @discardableResult
  public func send(_ message: Message) -> Bool {
    guard isAvailable, let data = try? encode(message) else { return false }
    guard channel.bufferedAmount + UInt64(data.count) <= 16 * 1024,
      channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    else { close(); return false }
    return true
  }

  public func close() {
    guard !closed else { return }
    closed = true
    receiver.stop()
    channel.delegate = nil
    channel.close()
    onAvailabilityChanged?(false)
    onAvailabilityChanged = nil; onMessage = nil
  }
}

/// WebRTC callbacks must not create an unbounded backlog of main-actor tasks.
/// One scheduled drain admits at most 256 messages / 64 KiB. Overflow closes the affected channel.
private final class ScreenSharingControlReceiver: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
  var deliver: (@MainActor @Sendable ([Data], Bool) -> Void)?
  var stateChanged: (@MainActor @Sendable () -> Void)?
  private let lock = NSLock()
  private var inbox = ScreenSharingControlInbox()

  func stop() { lock.withLock { inbox.stop() } }
  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    Task { @MainActor [weak self] in self?.stateChanged?() }
  }
  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    let schedule = lock.withLock { inbox.enqueue(buffer.data) }
    if schedule {
      Task { @MainActor [weak self] in
        guard let self else { return }
        let batch = self.lock.withLock { self.inbox.drain() }
        self.deliver?(batch.0, batch.1)
      }
    }
  }
}

/// Value state kept under the receiver's lock; independently exercises admission
/// limits without creating threads, media peers or event-loop timing in tests.
struct ScreenSharingControlInbox {
  private var packets: [Data] = []
  private var bytes = 0
  private var scheduled = false
  private var failed = false
  private var stopped = false

  mutating func enqueue(_ data: Data) -> Bool {
    guard !stopped else { return false }
    if packets.count >= 256 || data.count > ScreenSharingControlMessage.maximumBytes || bytes + data.count > 64 * 1024 {
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
    packets = []; bytes = 0; scheduled = false
    return result
  }
  mutating func stop() { stopped = true; packets = []; bytes = 0 }
}

public typealias ScreenSharingControlChannel = ScreenSharingDataChannel<ScreenSharingControlMessage>
public typealias ScreenSharingClipboardChannel = ScreenSharingDataChannel<ScreenSharingClipboardMessage>
