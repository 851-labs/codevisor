import Foundation
@preconcurrency import WebRTC
import ScreenSharing

/// Owns one peer's WebRTC objects — the factory with its network, worker and signaling threads,
/// the connection, the video source and tracks — and confines them to one serial queue. Every
/// call into the connection is a proxy that blocks until WebRTC's signaling (or worker) thread
/// answers, and releasing the last reference to the factory joins its three threads; neither
/// happens on the caller's thread any more. The main-actor peer asks the transport to do work
/// and awaits the answer, or fires and forgets.
///
/// The factory stays per peer: its encoder and decoder factory is the peer's own
/// `ScreenSharingCodecFactory`, which carries that peer's metrics, idle monitor, refresh signal,
/// recovery checks and delivery audit into every encoder and decoder WebRTC creates, and the
/// Objective-C factory API gives an encoder factory no way to tell which connection an encoder
/// is for. Sharing one factory would route every peer's codecs through one peer's state.
///
/// Teardown (`close(after:)`) never blocks the caller and is ordered: it waits for the data
/// channels' queues to finish (their sends and closes), closes the connection, waits for the
/// signaling thread to finish the callbacks the close produced, then releases everything here.
final class ScreenSharingPeerTransport: @unchecked Sendable {
  let queue: DispatchQueue
  // Everything below is touched only on `queue`.
  private var factory: RTCPeerConnectionFactory?
  private var connection: RTCPeerConnection?
  /// Objects the connection's media needs kept alive (the sender's source and track).
  private var retained: [AnyObject] = []
  /// The receiver's remote track and the renderer attached to it.
  private var remote: (track: RTCVideoTrack, renderer: any RTCVideoRenderer)?
  private var closing = false
  // Guarded by `lock`: who waits for the teardown to finish, and the diagnostic reference.
  private let lock = NSLock()
  private var diagnosticConnection: RTCPeerConnection?
  private var finished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private init(queue: DispatchQueue) { self.queue = queue }

  /// Runs `build` on a new transport's queue with an empty transport to fill in, and returns its
  /// result. Whatever `build` created and did not adopt is released there if it throws.
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

  /// During `build` only: the objects the transport now owns.
  func adopt(factory: RTCPeerConnectionFactory, connection: RTCPeerConnection) {
    dispatchPrecondition(condition: .onQueue(queue))
    self.factory = factory
    self.connection = connection
    lock.withLock { diagnosticConnection = connection }
  }

  /// The diagnostic RTC event log's synchronous boundary (the rig times the shipped API calls
  /// themselves): the connection, called on the caller's thread, until `close(after:)`. The queue
  /// keeps its own reference until teardown, which only starts after `close`, so the caller's
  /// reference is never the last one. Product code never calls this.
  func withDiagnosticConnection<Result>(_ body: (RTCPeerConnection) -> Result) -> Result? {
    guard let connection = lock.withLock({ diagnosticConnection }) else { return nil }
    return body(connection)
  }

  /// On the queue: keeps `object` alive until teardown, which releases it here.
  func retain(_ object: AnyObject) {
    dispatchPrecondition(condition: .onQueue(queue))
    retained.append(object)
  }

  /// Runs `body` with the connection on the queue and returns its result; throws once closed.
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

  /// Runs `body` with the connection on the queue; the connection is nil once closed.
  func inspect<Result: Sendable>(_ body: @escaping @Sendable (RTCPeerConnection?) -> Result) async -> Result {
    await withCheckedContinuation { continuation in
      queue.async { [self] in continuation.resume(returning: body(closing ? nil : connection)) }
    }
  }

  /// Runs `body` with the connection on the queue without waiting; nothing runs once closed.
  func run(_ body: @escaping @Sendable (RTCPeerConnection) -> Void) {
    queue.async { [self] in
      guard let connection, !closing else { return }
      body(connection)
    }
  }

  /// A completion-handler call into the connection (offer, answer, descriptions): issued on the
  /// queue, resumed by WebRTC's signaling thread.
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

  /// The receiver's remote video track arrived (on WebRTC's signaling thread): attach `renderer`
  /// on the queue, detaching it from any earlier track. A track arriving after close is dropped.
  func attach(_ track: RTCVideoTrack, renderer: any RTCVideoRenderer & Sendable) {
    nonisolated(unsafe) let track = track
    queue.async { [self] in
      guard connection != nil, !closing else { return }
      if let previous = remote { previous.track.remove(previous.renderer) }
      remote = (track, renderer)
      track.add(renderer)
    }
  }

  /// Starts the ordered teardown without waiting for it; idempotent. `channels` are the peer's
  /// data channels, already closed by the caller.
  func close(after channels: [any ScreenSharingQueuedChannel]) {
    lock.withLock { diagnosticConnection = nil }
    let group = DispatchGroup()
    for channel in channels { channel.afterQueuedWork(in: group) }
    queue.async { [self] in closing = true }
    group.notify(queue: queue) { [self] in release() }
  }

  /// Returns once `close(after:)` released every WebRTC object; immediately after that.
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

  /// On the queue: close, let the signaling thread finish what the close produced, release.
  private func release() {
    dispatchPrecondition(condition: .onQueue(queue))
    closing = true
    if let remote { remote.track.remove(remote.renderer) }
    remote = nil
    if let connection {
      connection.close()
      // A proxied call queues behind every callback the close posted to the signaling thread:
      // once it returns, no callback still holds a wrapper whose release could fall to that
      // thread (and make it join itself releasing the factory).
      _ = connection.signalingState
    }
    connection = nil
    retained.removeAll()
    // The factory's threads are joined here unless a data channel's queue still holds the last
    // reference, in which case they are joined there; never on the main thread.
    factory = nil
    let waiting = lock.withLock {
      finished = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }

  deinit {
    // A transport dropped without `close` (a peer abandoned before it was closed) still closes
    // and releases its objects on its own queue.
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

/// A data channel whose WebRTC object lives on its own queue; the peer's teardown waits for it.
protocol ScreenSharingQueuedChannel: Sendable {
  func afterQueuedWork(in group: DispatchGroup)
}

extension ScreenSharingDataChannel: ScreenSharingQueuedChannel {}
