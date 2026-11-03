import Foundation
import Synchronization

public final class ScreenSharingV2MediaFeed: Sendable {
  public typealias Datagrams = @Sendable (ScreenSharingDatagramKind, Data) -> Void

  private let transport: any ScreenSharingMediaTransport
  private let tap = Mutex<Tap?>(nil)
  private let pump = Mutex<Task<Void, Never>?>(nil)

  public init(transport: any ScreenSharingMediaTransport, datagrams: @escaping Datagrams) {
    self.transport = transport
    let task = Task { [weak self] in
      while let event = await transport.nextEvent() {
        if case .datagram(let kind, let payload) = event {
          datagrams(kind, payload)
        } else {
          self?.tap.withLock { $0 }?.deliver(event)
        }
      }
      self?.tap.withLock { $0 }?.finish()
    }
    pump.withLock { $0 = task }
  }

  public func sendDatagram(_ kind: ScreenSharingDatagramKind, _ payload: Data) -> Bool {
    transport.sendDatagram(kind, payload)
  }

  public func attach() -> any ScreenSharingMediaTransport {
    let next = Tap(transport: transport)
    tap.withLock { current in
      current?.finish()
      current = next
    }
    return next
  }

  public func close() {
    pump.withLock { $0?.cancel() }
    tap.withLock { $0?.finish() }
    transport.close()
  }
}

private final class Tap: ScreenSharingMediaTransport, @unchecked Sendable {
  private let transport: any ScreenSharingMediaTransport
  private var events: AsyncStream<ScreenSharingMediaEvent>.Iterator
  private let continuation: AsyncStream<ScreenSharingMediaEvent>.Continuation
  private let closed = Atomic(false)

  init(transport: any ScreenSharingMediaTransport) {
    self.transport = transport
    let (stream, continuation) = AsyncStream<ScreenSharingMediaEvent>.makeStream(bufferingPolicy: .unbounded)
    events = stream.makeAsyncIterator()
    self.continuation = continuation
  }

  func deliver(_ event: ScreenSharingMediaEvent) {
    continuation.yield(event)
  }

  func finish() {
    closed.store(true, ordering: .relaxed)
    continuation.finish()
  }

  @discardableResult
  func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws -> UInt32 {
    guard !closed.load(ordering: .relaxed) else { throw CancellationError() }

    return try transport.send(tile, meta: meta)
  }

  func admission() -> ScreenSharingMediaAdmission { transport.admission() }

  func nextEvent() async -> ScreenSharingMediaEvent? {
    await events.next()
  }

  func acknowledge(ltrToken: UInt64, stream: UInt8) { transport.acknowledge(ltrToken: ltrToken, stream: stream) }

  func requestRefresh(stream: UInt8, keyframe: Bool) { transport.requestRefresh(stream: stream, keyframe: keyframe) }

  var roundTripUs: UInt64 { transport.roundTripUs }

  var lossRate: Double { transport.lossRate }

  func close() {
    finish()
  }
}
