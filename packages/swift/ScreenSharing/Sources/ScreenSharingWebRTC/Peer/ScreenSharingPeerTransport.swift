import Foundation
@preconcurrency import WebRTC
import ScreenSharing

final class ScreenSharingPeerTransport: @unchecked Sendable {
  let queue: DispatchQueue
  private var factory: RTCPeerConnectionFactory?
  private var connection: RTCPeerConnection?
  private var retained: [AnyObject] = []
  private var remote: (track: RTCVideoTrack, renderer: any RTCVideoRenderer)?
  private var closing = false
  private let lock = NSLock()
  private var diagnosticConnection: RTCPeerConnection?
  private var finished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private init(queue: DispatchQueue) { self.queue = queue }

  static func build<Result: Sendable>(
    _ build: @escaping @Sendable (ScreenSharingPeerTransport) throws -> Result
  ) async throws -> Result {
    let transport = ScreenSharingPeerTransport(
      queue: DispatchQueue(label: "codevisor.screen-sharing.peer", qos: .userInitiated))
    return try await withCheckedThrowingContinuation { continuation in
      transport.queue.async {
        do {
          continuation.resume(returning: try build(transport))
        } catch {
          transport.release()
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func adopt(factory: RTCPeerConnectionFactory, connection: RTCPeerConnection) {
    dispatchPrecondition(condition: .onQueue(queue))
    self.factory = factory
    self.connection = connection
    lock.withLock { diagnosticConnection = connection }
  }

  func withDiagnosticConnection<Result>(_ body: (RTCPeerConnection) -> Result) -> Result? {
    guard let connection = lock.withLock({ diagnosticConnection }) else { return nil }
    return body(connection)
  }

  func retain(_ object: AnyObject) {
    dispatchPrecondition(condition: .onQueue(queue))
    retained.append(object)
  }

  func perform<Result: Sendable>(
    _ body: @escaping @Sendable (RTCPeerConnection) throws -> Result
  ) async throws
    -> Result
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard let connection, !closing else {
          continuation.resume(throwing: ScreenSharingError.invalid("Peer is closed."))
          return
        }
        do { continuation.resume(returning: try body(connection)) } catch { continuation.resume(throwing: error) }
      }
    }
  }

  func inspect<Result: Sendable>(_ body: @escaping @Sendable (RTCPeerConnection?) -> Result) async -> Result {
    await withCheckedContinuation { continuation in
      queue.async { [self] in continuation.resume(returning: body(closing ? nil : connection)) }
    }
  }

  func run(_ body: @escaping @Sendable (RTCPeerConnection) -> Void) {
    queue.async { [self] in
      guard let connection, !closing else { return }
      body(connection)
    }
  }

  func call<Result: Sendable>(
    _ body:
      @escaping @Sendable (RTCPeerConnection, @escaping @Sendable (Swift.Result<Result, any Error>) -> Void) ->
      Void
  ) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard let connection, !closing else {
          continuation.resume(throwing: ScreenSharingError.invalid("Peer is closed."))
          return
        }
        body(connection) { continuation.resume(with: $0) }
      }
    }
  }

  func attach(_ track: RTCVideoTrack, renderer: any RTCVideoRenderer & Sendable) {
    nonisolated(unsafe) let track = track
    queue.async { [self] in
      guard connection != nil, !closing else { return }
      if let previous = remote { previous.track.remove(previous.renderer) }
      remote = (track, renderer)
      track.add(renderer)
    }
  }

  func close(after channels: [any ScreenSharingQueuedChannel]) {
    lock.withLock { diagnosticConnection = nil }
    let group = DispatchGroup()
    for channel in channels { channel.afterQueuedWork(in: group) }
    queue.async { [self] in closing = true }
    group.notify(queue: queue) { [self] in release() }
  }

  func awaitTeardown() async {
    await withCheckedContinuation { continuation in
      let done = lock.withLock {
        if finished { return true }
        waiters.append(continuation)
        return false
      }
      if done { continuation.resume() }
    }
  }

  private func release() {
    dispatchPrecondition(condition: .onQueue(queue))
    closing = true
    if let remote { remote.track.remove(remote.renderer) }
    remote = nil
    if let connection {
      connection.close()
      _ = connection.signalingState
    }
    connection = nil
    retained.removeAll()
    factory = nil
    let waiting = lock.withLock {
      finished = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }

  deinit {
    guard connection != nil || factory != nil || !retained.isEmpty || remote != nil else { return }
    let objects = Abandoned(
      factory: factory, connection: connection, retained: retained, remote: remote)
    queue.async {
      if let remote = objects.remote { remote.track.remove(remote.renderer) }
      objects.connection?.close()
      _ = objects.connection?.signalingState
      withExtendedLifetime(objects) {}
    }
  }

  private final class Abandoned: @unchecked Sendable {
    let factory: RTCPeerConnectionFactory?
    let connection: RTCPeerConnection?
    let retained: [AnyObject]
    let remote: (track: RTCVideoTrack, renderer: any RTCVideoRenderer)?
    init(
      factory: RTCPeerConnectionFactory?, connection: RTCPeerConnection?, retained: [AnyObject],
      remote: (track: RTCVideoTrack, renderer: any RTCVideoRenderer)?
    ) {
      self.factory = factory; self.connection = connection; self.retained = retained; self.remote = remote
    }
  }
}

protocol ScreenSharingQueuedChannel: Sendable {
  func afterQueuedWork(in group: DispatchGroup)
}

extension ScreenSharingDataChannel: ScreenSharingQueuedChannel {}
