import Foundation
import ScreenSharing
import Synchronization

public final class ScreenSharingV2LocalConnection: ScreenSharingV2Connection, Sendable {
  public let remoteId: String
  private let link: Link
  private let side: Side

  private init(remoteId: String, link: Link, side: Side) {
    self.remoteId = remoteId
    self.link = link
    self.side = side
  }

  public static func pair(
    endpointId: String
  ) -> (host: ScreenSharingV2LocalConnection, viewer: ScreenSharingV2LocalConnection) {
    let link = Link()
    return (
      ScreenSharingV2LocalConnection(remoteId: endpointId, link: link, side: .host),
      ScreenSharingV2LocalConnection(remoteId: endpointId, link: link, side: .viewer)
    )
  }

  public var route: ScreenSharingV2Route? { nil }

  public func openStream() async throws -> any ScreenSharingV2MessageStream {
    try link.openStream(from: side)
  }

  public func acceptStream() async throws -> any ScreenSharingV2MessageStream {
    guard let stream = await link.accepted[side].next() else { throw ScreenSharingV2LocalConnection.closedError }

    return stream
  }

  public func openMedia() async -> any ScreenSharingMediaTransport {
    link.media[side]
  }

  public func mediaStatistics() -> [String: String] {
    let received = link.media[side].received
    return [
      "v2.route": "local", "v2.framesReceived": String(received.frames), "v2.bytesReceived": String(received.bytes),
    ]
  }

  public func closed() async -> String {
    await link.closed()
  }

  public func close(_ reason: String) {
    link.close(reason)
  }

  static let closedError = ScreenSharingError.unavailable("The local screen-sharing connection closed.")

  enum Side {
    case host
    case viewer

    var other: Side { self == .host ? .viewer : .host }
  }

  struct BySide<Value: Sendable>: Sendable {
    let host: Value
    let viewer: Value

    subscript(side: Side) -> Value { side == .host ? host : viewer }
  }

  private final class Link: Sendable {
    private struct State {
      var reason: String?
      var waiters: [CheckedContinuation<String, Never>] = []
      var streams: [ScreenSharingV2LocalMessageStream] = []
    }

    let accepted = BySide(host: LocalQueue<ScreenSharingV2LocalMessageStream>(), viewer: LocalQueue())
    let media: BySide<ScreenSharingV2LocalMediaTransport>
    private let state = Mutex(State())

    init() {
      let (host, viewer) = ScreenSharingV2LocalMediaTransport.pair()
      media = BySide(host: host, viewer: viewer)
    }

    func openStream(from side: Side) throws -> any ScreenSharingV2MessageStream {
      let (local, remote) = ScreenSharingV2LocalMessageStream.pair()
      try state.withLock { state in
        guard state.reason == nil else { throw ScreenSharingV2LocalConnection.closedError }

        state.streams += [local, remote]
      }
      accepted[side.other].push(remote)
      return local
    }

    func closed() async -> String {
      await withCheckedContinuation { continuation in
        let reason = state.withLock { state in
          if state.reason == nil { state.waiters.append(continuation) }
          return state.reason
        }
        if let reason { continuation.resume(returning: reason) }
      }
    }

    func close(_ reason: String) {
      let ended = state.withLock {
        state -> (waiters: [CheckedContinuation<String, Never>], streams: [ScreenSharingV2LocalMessageStream])? in
        guard state.reason == nil else { return nil }

        state.reason = reason
        defer { state.waiters = []; state.streams = [] }
        return (state.waiters, state.streams)
      }
      guard let ended else { return }

      for side in [Side.host, .viewer] {
        accepted[side].finish()
        media[side].close()
      }
      for stream in ended.streams { stream.terminate() }
      for waiter in ended.waiters { waiter.resume(returning: reason) }
    }
  }
}

final class LocalQueue<Element: Sendable>: @unchecked Sendable {
  private let continuation: AsyncStream<Element>.Continuation
  private var iterator: AsyncStream<Element>.Iterator

  init() {
    let (stream, continuation) = AsyncStream<Element>.makeStream()
    self.continuation = continuation
    iterator = stream.makeAsyncIterator()
  }

  @discardableResult
  func push(_ element: Element) -> Bool {
    guard case .enqueued = continuation.yield(element) else { return false }

    return true
  }

  func next() async -> Element? {
    var next = iterator
    defer { iterator = next }
    return await next.next()
  }

  func finish() {
    continuation.finish()
  }
}

final class ScreenSharingV2LocalMessageStream: ScreenSharingV2MessageStream, Sendable {
  private let inbox = LocalQueue<Data>()
  private let peer = Mutex<ScreenSharingV2LocalMessageStream?>(nil)

  private init() {}

  static func pair() -> (ScreenSharingV2LocalMessageStream, ScreenSharingV2LocalMessageStream) {
    let first = ScreenSharingV2LocalMessageStream()
    let second = ScreenSharingV2LocalMessageStream()
    first.peer.withLock { $0 = second }
    second.peer.withLock { $0 = first }
    return (first, second)
  }

  func send(_ payload: Data) async throws {
    guard peer.withLock({ $0 })?.inbox.push(payload) == true else { throw ScreenSharingV2LocalConnection.closedError }
  }

  func receive() async throws -> Data? {
    await inbox.next()
  }

  func finish() async {
    peer.withLock { $0 }?.inbox.finish()
  }

  func terminate() {
    inbox.finish()
    peer.withLock { $0 = nil }
  }
}

final class ScreenSharingV2LocalMediaTransport: ScreenSharingMediaTransport, Sendable {
  static let backlogLimit = 8 * 1024 * 1024

  private struct State {
    var peer: ScreenSharingV2LocalMediaTransport?
    var closed = false
    var nextFrame: [UInt8: UInt32] = [:]
    var backlogBytes = 0
    var sentAtNs: [FrameKey: Int64] = [:]
    var received = (frames: 0, bytes: 0)
  }

  private struct FrameKey: Hashable {
    let stream: UInt8
    let frame: UInt32
  }

  private let state = Mutex(State())
  private let events = LocalQueue<ScreenSharingMediaEvent>()

  private init() {}

  static func pair() -> (host: ScreenSharingV2LocalMediaTransport, viewer: ScreenSharingV2LocalMediaTransport) {
    let host = ScreenSharingV2LocalMediaTransport()
    let viewer = ScreenSharingV2LocalMediaTransport()
    host.state.withLock { $0.peer = viewer }
    viewer.state.withLock { $0.peer = host }
    return (host, viewer)
  }

  var received: (frames: Int, bytes: Int) { state.withLock { $0.received } }

  @discardableResult
  func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws -> UInt32 {
    let stream = UInt8(tile.tile)
    let (number, peer) = try state.withLock { state in
      guard !state.closed, let peer = state.peer else { throw ScreenSharingV2LocalConnection.closedError }

      let number = state.nextFrame[stream, default: 0]
      state.nextFrame[stream] = number &+ 1
      return (number, peer)
    }
    peer.arrive(
      ScreenSharingReceivedFrame(
        stream: stream, frame: number, isKeyFrame: tile.isKeyFrame, ltrToken: tile.ltrToken, meta: meta,
        payload: tile.accessUnit, assemblingUs: 0, recovery: .none))
    return number
  }

  func admission() -> ScreenSharingMediaAdmission {
    let backlog = peer?.backlogBytes ?? 0
    let ceilingKbps = UInt64(ScreenSharingV2Profile.bitrateCeiling / 1000)
    return ScreenSharingMediaAdmission(
      admit: backlog < Self.backlogLimit, backlogBytes: UInt64(backlog), estimateKbps: ceilingKbps * 4,
      encoderCeilingKbps: ceilingKbps, sampled: true)
  }

  func nextEvent() async -> ScreenSharingMediaEvent? {
    guard let event = await events.next() else { return nil }

    if case .frame(let frame) = event { taken(frame) }
    return event
  }

  func acknowledge(ltrToken: UInt64, stream: UInt8) {
    peer?.events.push(.ltrAcked(stream: stream, token: ltrToken))
  }

  func requestRefresh(stream: UInt8, keyframe: Bool) {
    peer?.events.push(.refreshRequested(stream: stream, keyframe: keyframe))
  }

  var roundTripUs: UInt64 { 0 }

  var lossRate: Double { 0 }

  func close() {
    state.withLock { $0.closed = true }
    events.finish()
  }

  func sendDatagram(_ kind: ScreenSharingDatagramKind, _ payload: Data) -> Bool {
    peer?.events.push(.datagram(kind, payload)) ?? false
  }

  private var peer: ScreenSharingV2LocalMediaTransport? {
    state.withLock { $0.closed ? nil : $0.peer }
  }

  private var backlogBytes: Int { state.withLock { $0.backlogBytes } }

  private func arrive(_ frame: ScreenSharingReceivedFrame) {
    let open = state.withLock { state in
      guard !state.closed else { return false }

      state.backlogBytes += frame.payload.count
      state.sentAtNs[FrameKey(stream: frame.stream, frame: frame.frame)] = ScreenSharingMetrics.nowNs
      return true
    }
    if open { events.push(.frame(frame)) }
  }

  private func taken(_ frame: ScreenSharingReceivedFrame) {
    let (host, sentAtNs) = state.withLock { state in
      state.received.frames += 1
      state.received.bytes += frame.payload.count
      state.backlogBytes -= frame.payload.count
      let sentAtNs = state.sentAtNs.removeValue(forKey: FrameKey(stream: frame.stream, frame: frame.frame))
      return (state.closed ? nil : state.peer, sentAtNs)
    }
    let waitedUs = sentAtNs.map { UInt64(max(0, ScreenSharingMetrics.nowNs - $0) / 1000) } ?? 0
    host?.events.push(
      .frameAcked(
        ScreenSharingFrameAck(
          stream: frame.stream, frame: frame.frame, queuedUs: waitedUs, sendingUs: 0, ackedAfterUs: waitedUs)))
  }
}
