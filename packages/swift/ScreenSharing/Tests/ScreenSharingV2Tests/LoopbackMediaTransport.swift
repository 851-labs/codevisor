import CodevisorTestSupport
import Foundation
import Synchronization

@testable import ScreenSharingV2

final class LoopbackMediaTransport: ScreenSharingMediaTransport, @unchecked Sendable {
  private struct State {
    var peer: LoopbackMediaTransport?
    var admits = true
    var dropsNext = false
    var corruptsNext = false
    var nextFrame: UInt32 = 0
    var sent: [ScreenSharingEncodedTile] = []
    var requested: [(stream: UInt8, keyframe: Bool)] = []
  }

  let admissionChecks = TestSignal()
  let sends = TestSignal()
  let dropped = TestSignal()
  let ltrAcknowledgements = TestSignal()
  let refreshRequests = TestSignal()
  private let state = Mutex(State())
  private let events: AsyncStream<ScreenSharingMediaEvent>
  private let continuation: AsyncStream<ScreenSharingMediaEvent>.Continuation
  private var iterator: AsyncStream<ScreenSharingMediaEvent>.Iterator

  init() {
    (events, continuation) = AsyncStream.makeStream(of: ScreenSharingMediaEvent.self)
    iterator = events.makeAsyncIterator()
  }

  static func pair() -> (host: LoopbackMediaTransport, viewer: LoopbackMediaTransport) {
    let host = LoopbackMediaTransport()
    let viewer = LoopbackMediaTransport()
    host.state.withLock { $0.peer = viewer }
    viewer.state.withLock { $0.peer = host }
    return (host, viewer)
  }

  var sent: [ScreenSharingEncodedTile] { state.withLock { $0.sent } }
  var requestedRefreshes: [(stream: UInt8, keyframe: Bool)] { state.withLock { $0.requested } }

  func setAdmits(_ admits: Bool) {
    state.withLock { $0.admits = admits }
  }

  func dropNextFrame() {
    state.withLock { $0.dropsNext = true }
  }

  func corruptNextFrame() {
    state.withLock { $0.corruptsNext = true }
  }

  func emit(_ event: ScreenSharingMediaEvent) {
    continuation.yield(event)
  }

  @discardableResult
  func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws -> UInt32 {
    let (number, peer, drops, corrupts) = state.withLock { state in
      defer {
        state.nextFrame += 1
        state.dropsNext = false
        state.corruptsNext = false
        state.sent.append(tile)
      }
      return (state.nextFrame, state.peer, state.dropsNext, state.corruptsNext)
    }
    sends.signal()
    if drops {
      dropped.signal()
    } else {
      peer?.emit(.frame(Self.received(tile, number: number, meta: meta, corrupt: corrupts)))
    }
    return number
  }

  func admission() -> ScreenSharingMediaAdmission {
    defer { admissionChecks.signal() }
    let admits = state.withLock { $0.admits }
    return ScreenSharingMediaAdmission(
      admit: admits, backlogBytes: 0, estimateKbps: 100_000, encoderCeilingKbps: 85_000, sampled: true)
  }

  func nextEvent() async -> ScreenSharingMediaEvent? {
    var next = iterator
    defer { iterator = next }
    return await next.next()
  }

  func acknowledge(ltrToken: UInt64, stream: UInt8) {
    state.withLock { $0.peer }?.emit(.ltrAcked(stream: stream, token: ltrToken))
    ltrAcknowledgements.signal()
  }

  func requestRefresh(stream: UInt8, keyframe: Bool) {
    let peer = state.withLock { state in
      state.requested.append((stream, keyframe))
      return state.peer
    }
    peer?.emit(.refreshRequested(stream: stream, keyframe: keyframe))
    refreshRequests.signal()
  }

  var roundTripUs: UInt64 { 0 }

  var lossRate: Double { 0 }

  func close() {
    continuation.finish()
  }

  private static func received(
    _ tile: ScreenSharingEncodedTile, number: UInt32, meta: Data, corrupt: Bool
  ) -> ScreenSharingReceivedFrame {
    let copy = corrupt ? Data([0, 0, 0, 9, 2, 1]) : tile.accessUnit.withUnsafeBytes { Data($0) }
    return ScreenSharingReceivedFrame(
      stream: UInt8(tile.tile), frame: number, isKeyFrame: tile.isKeyFrame, ltrToken: tile.ltrToken, meta: meta,
      payload: ScreenSharingAccessUnit(copy), assemblingUs: 0, recovery: .none)
  }
}
