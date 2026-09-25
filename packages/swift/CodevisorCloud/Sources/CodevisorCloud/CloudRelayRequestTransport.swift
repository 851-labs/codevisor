import ACPKit
import CodevisorClient
import Foundation

public enum CloudRelayTransportError: Error, Equatable, Sendable, LocalizedError {
  case invalidRequest
  case invalidFrame
  case channelClosed(CloudChannelCloseReason?)
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .invalidRequest:
      "The request cannot be sent over the cloud relay."
    case .invalidFrame:
      "The machine sent an unexpected relay frame."
    case let .channelClosed(reason):
      switch reason {
      case .rejected:
        "The machine rejected the request."
      case .none:
        "The cloud relay connection was interrupted."
      default:
        "The relay channel closed (\(reason?.rawValue ?? "unknown"))."
      }
    case .timedOut:
      // Deliberately transport-neutral: the same client serves the
      // cloud relay and the direct LAN pipe, and naming the relay for
      // a LAN failure sent users debugging the wrong path.
      "The request to the machine timed out."
    }
  }
}

/// Shared window sizing for the flow-controlled http/ws relay channels
/// (twin of @codevisor/cloud-client PROXY_INITIAL_CREDIT_BYTES): each
/// receiver grants this much ciphertext budget up front and replenishes as
/// it consumes, so no hop ever holds more than the window in flight.
enum CloudRelayProxy {
  static let initialCreditBytes = 1024 * 1024
}

/// Tunnels ordinary HTTP requests through a flow-controlled "http" relay
/// channel: the open params carry method/path/headers, the body streams as
/// base64url chunks (gated on the machine's credit grants), and the machine
/// answers head → chunks → end → close("done") behind ours. `stream(for:)`
/// hands chunks to the caller as they arrive and replenishes the machine's
/// window per pulled chunk, so a 32MB download is paced by its consumer
/// instead of buffered anywhere.
public struct CloudRelayRequestTransport: ServerRequestTransport {
  /// Raw bytes per body chunk frame (b64url expansion happens on top).
  public static let chunkSize = 262_144
  /// A relayed request whose channel never answers must fail visibly
  /// instead of hanging its caller (and any UI gated on it) forever.
  public static let defaultTimeout: Duration = .seconds(30)

  private let endpoint: any CloudChannelTransport
  private let timeout: Duration
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    endpoint: any CloudChannelTransport,
    timeout: Duration = CloudRelayRequestTransport.defaultTimeout,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.endpoint = endpoint
    self.timeout = timeout
    self.sleep = sleep
  }

  private struct ClientFrame: Encodable {
    var kind: String
    var data: String?
  }

  struct MachineFrame: Decodable {
    var kind: String
    var status: Int?
    var headers: [String: String]?
    var data: String?
  }

  struct WireFrame {
    var frame: MachineFrame
    var sealedBytes: Int
  }

  /// The whole request/response under one deadline, body buffered — the
  /// JSON API surface. Streaming callers use `stream(for:)`.
  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let requestTimeout = timeout(for: request)
    return try await raced(expiry: { [sleep] in try await sleep(requestTimeout) }) { deadline in
      let (response, source) = try await performStream(
        request, body: .data(request.httpBody), deadline: deadline)
      return try await Self.collect(response, source)
    }
  }

  /// Streams the file as request body chunks, reading one chunk at a time
  /// so a large upload never sits in memory. A fixed deadline would cap an
  /// upload's size by the link speed, so the body runs under an idle
  /// deadline instead: every chunk sent and every credit grant restarts the
  /// timer. Once the end frame is out, the response gets the normal timeout.
  public func upload(
    for request: URLRequest,
    fromFile fileURL: URL
  ) async throws -> (Data, HTTPURLResponse) {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    let watchdog = IdleWatchdog(timeout: timeout, sleep: sleep)
    return try await raced(expiry: { try await watchdog.waitForExpiry() }) { deadline in
      let (response, source) = try await performStream(
        request, body: .file(handle, watchdog), deadline: deadline)
      return try await Self.collect(response, source)
    }
  }

  private static func collect(
    _ response: HTTPURLResponse,
    _ source: HttpResponseSource
  ) async throws -> (Data, HTTPURLResponse) {
    var body = Data()
    do {
      while let chunk = try await source.nextBodyChunk() {
        body.append(chunk)
      }
    } catch {
      await source.finish(reason: .done)
      throw error
    }
    return (body, response)
  }

  /// Streams the response: the head is bounded by the transport timeout,
  /// the body is paced by the consumer (each pulled chunk replenishes the
  /// machine's send window). The stream must be drained or cancelled — a
  /// cancelled/failed pull closes the channel on the way out.
  public func stream(
    for request: URLRequest
  ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    let (response, source) = try await raced(expiry: { [sleep, timeout] in try await sleep(timeout) }) {
      deadline in
      try await performStream(request, body: .data(request.httpBody), deadline: deadline)
    }
    let body = AsyncThrowingStream<Data, any Error>(unfolding: {
      do {
        return try await source.nextBodyChunk()
      } catch {
        await source.finish(reason: .done)
        throw error
      }
    })
    return (response, body)
  }

  /// URLRequest's own default `timeoutInterval`: a request carrying any
  /// other value set it deliberately (a clone that legitimately runs for
  /// minutes, a config read that should give up early), and a direct
  /// connection would honor it, so the relay does too.
  static let urlRequestDefaultTimeout: TimeInterval = 60

  private func timeout(for request: URLRequest) -> Duration {
    request.timeoutInterval == Self.urlRequestDefaultTimeout
      ? timeout : .seconds(request.timeoutInterval)
  }

  /// Races `operation` against the transport deadline (`expiry` returns
  /// once it passes); the loser is cancelled (cancellation unblocks the
  /// frame stream, and the request path then closes its channel on the way
  /// out).
  private func raced<Value: Sendable>(
    expiry: @escaping @Sendable () async throws -> Void,
    _ operation: @escaping @Sendable (DeadlineFlag) async throws -> Value
  ) async throws -> Value {
    let deadline = DeadlineFlag()
    return try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask {
        try await operation(deadline)
      }
      group.addTask {
        try await expiry()
        // Marked before the operation is cancelled, so its unwind can
        // tell a deadline from a caller's cancellation.
        deadline.markExpired()
        throw CloudRelayTransportError.timedOut
      }
      guard let result = try await group.next() else {
        throw CloudRelayTransportError.timedOut
      }
      group.cancelAll()
      return result
    }
  }

  /// Opens the channel, uploads the request, and consumes frames up to and
  /// including the head. The returned source yields decoded body chunks.
  /// Whether the transport deadline fired for one request.
  final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func markExpired() { lock.withLock { expired = true } }
    var hasExpired: Bool { lock.withLock { expired } }
  }

  /// Where a request's body comes from: buffered bytes, or a file read one
  /// chunk at a time whose progress feeds the upload's idle deadline.
  /// @unchecked: the file handle is read only by the single sending task.
  enum RequestBody: @unchecked Sendable {
    case data(Data?)
    case file(FileHandle, IdleWatchdog)

    var watchdog: IdleWatchdog? {
      if case let .file(_, watchdog) = self { return watchdog }
      return nil
    }
  }

  private func performStream(
    _ request: URLRequest,
    body: RequestBody,
    deadline: DeadlineFlag
  ) async throws -> (HTTPURLResponse, HttpResponseSource) {
    guard let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw CloudRelayTransportError.invalidRequest }
    var path = components.path.isEmpty ? "/" : components.path
    if let query = components.query, !query.isEmpty {
      path += "?\(query)"
    }
    let headers = request.allHTTPHeaderFields ?? [:]
    let params: JSONValue = .object([
      "method": .string(request.httpMethod ?? "GET"),
      "path": .string(path),
      "headers": .object(headers.mapValues { .string($0) }),
    ])

    let (frames, continuation) = AsyncThrowingStream<WireFrame, any Error>.makeStream()
    let gate = CloudChannelCreditGate()
    let decoder = JSONDecoder()
    let channel = try await endpoint.openFlowControlledChannel(
      channelType: "http",
      params: params,
      compressed: true,
      onMessage: { data, sealedBytes in
        if let frame = try? decoder.decode(MachineFrame.self, from: data) {
          continuation.yield(WireFrame(frame: frame, sealedBytes: sealedBytes))
        } else {
          continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
        }
      },
      onCredit: { bytes in
        // A grant is progress: the machine is draining the upload.
        body.watchdog?.touch()
        gate.add(bytes)
      },
      onClosed: { reason in
        gate.fail(CloudRelayTransportError.channelClosed(reason))
        if reason == .done {
          continuation.finish()
        } else {
          continuation.finish(throwing: CloudRelayTransportError.channelClosed(reason))
        }
      }
    )
    let source = HttpResponseSource(channel: channel, frames: frames)
    do {
      try await channel.grantCredit(bytes: CloudRelayProxy.initialCreditBytes)
      try await sendRequestBody(body, channel: channel, gate: gate)
      let response = try await source.readHead(url: url)
      return (response, source)
    } catch {
      // No head by the deadline: let the pipe judge whether the machine
      // answered at all (the host ignores channels that saw traffic).
      if deadline.hasExpired { await channel.reportUnanswered() }
      await source.finish(reason: .done)
      throw error
    }
  }

  /// Uploads the body as chunk frames and the terminating end frame, each
  /// gated on the machine's request-body window.
  private func sendRequestBody(
    _ body: RequestBody,
    channel: CloudRelayChannel,
    gate: CloudChannelCreditGate
  ) async throws {
    let encoder = JSONEncoder()
    func send(_ frame: ClientFrame) async throws {
      let payload = try encoder.encode(frame)
      try await gate.consume(
        CloudChannelCreditGate.sealedCost(plaintextBytes: payload.count, compressed: true))
      _ = try await channel.send(plaintext: payload)
    }
    func sendChunk(_ bytes: Data) async throws {
      try await send(ClientFrame(kind: "chunk", data: CloudChannelCrypto.base64URLEncode(bytes)))
    }
    switch body {
    case let .data(data):
      if let data, !data.isEmpty {
        var offset = data.startIndex
        while offset < data.endIndex {
          let end =
            data.index(offset, offsetBy: Self.chunkSize, limitedBy: data.endIndex)
            ?? data.endIndex
          try await sendChunk(data[offset..<end])
          offset = end
        }
      }
      try await send(ClientFrame(kind: "end"))
    case let .file(handle, watchdog):
      while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
        try Task.checkCancellation()
        try await sendChunk(chunk)
        watchdog.touch()
      }
      try await send(ClientFrame(kind: "end"))
      // The body is out: from here the response runs under one fixed
      // timeout, which later credit grants must not extend.
      watchdog.freeze()
    }
  }
}

/// The idle deadline for a streamed upload: expires once `timeout` passes
/// with no `touch()`. Each touch restarts the timer; `freeze()` restarts it
/// one last time and ignores later touches, so the tail of the request gets
/// a plain fixed deadline.
final class IdleWatchdog: @unchecked Sendable {
  private let timeout: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let lock = NSLock()
  private var generation = 0
  private var frozen = false
  private var finished = false
  private var timer: Task<Void, Never>?
  private var waiter: CheckedContinuation<Void, any Error>?

  init(timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.timeout = timeout
    self.sleep = sleep
    touch()
  }

  func touch() {
    restart(freezing: false)
  }

  func freeze() {
    restart(freezing: true)
  }

  private func restart(freezing: Bool) {
    let previous: Task<Void, Never>? = lock.withLock {
      guard !frozen, !finished else { return nil }
      frozen = freezing
      generation += 1
      let current = generation
      let previous = timer
      timer = Task { [weak self, sleep, timeout] in
        do {
          try await sleep(timeout)
        } catch {
          return
        }
        self?.expire(generation: current)
      }
      return previous
    }
    previous?.cancel()
  }

  private func expire(generation fired: Int) {
    let resume: CheckedContinuation<Void, any Error>? = lock.withLock {
      // A stale timer lost its race with the touch that replaced it.
      guard fired == generation, !finished else { return nil }
      // With no waiter yet, `finished` makes the next wait return at once.
      finished = true
      defer { waiter = nil }
      return waiter
    }
    resume?.resume()
  }

  /// Returns once the deadline passes. Cancelling the wait (the request
  /// finished first) also stops the timer.
  func waitForExpiry() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let alreadyExpired: Bool = lock.withLock {
          if finished { return true }
          waiter = continuation
          return false
        }
        if alreadyExpired { continuation.resume() }
      }
    } onCancel: {
      let (resume, timer): (CheckedContinuation<Void, any Error>?, Task<Void, Never>?) = lock.withLock {
        finished = true
        defer {
          waiter = nil
          self.timer = nil
        }
        return (waiter, self.timer)
      }
      timer?.cancel()
      resume?.resume(throwing: CancellationError())
    }
  }
}

/// Single-consumer pull surface over one http channel's machine frames:
/// `readHead` then `nextBodyChunk` until nil. Every consumed frame
/// replenishes the machine's window, so the machine reads its local response
/// exactly as fast as this side is pulled. @unchecked Sendable covers the
/// iterator handoff between the opening task and the body consumer — the
/// single-consumer contract (like a URLSession receive loop) makes the
/// accesses sequential.
final class HttpResponseSource: @unchecked Sendable {
  private let channel: CloudRelayChannel
  private var iterator: AsyncThrowingStream<CloudRelayRequestTransport.WireFrame, any Error>.Iterator
  private var finished = false

  init(
    channel: CloudRelayChannel,
    frames: AsyncThrowingStream<CloudRelayRequestTransport.WireFrame, any Error>
  ) {
    self.channel = channel
    iterator = frames.makeAsyncIterator()
  }

  func readHead(url: URL) async throws -> HTTPURLResponse {
    guard let wire = try await iterator.next() else {
      throw CloudRelayTransportError.channelClosed(nil)
    }
    try? await channel.grantCredit(bytes: wire.sealedBytes)
    guard wire.frame.kind == "head", let status = wire.frame.status,
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: wire.frame.headers ?? [:]
      )
    else { throw CloudRelayTransportError.invalidFrame }
    return response
  }

  /// The next decoded body chunk, or nil after the machine's end frame
  /// (which also closes the channel from this side).
  func nextBodyChunk() async throws -> Data? {
    while true {
      guard !finished else { return nil }
      guard let wire = try await iterator.next() else {
        throw CloudRelayTransportError.channelClosed(nil)
      }
      try? await channel.grantCredit(bytes: wire.sealedBytes)
      switch wire.frame.kind {
      case "chunk":
        guard let encoded = wire.frame.data,
          let chunk = CloudChannelCrypto.base64URLDecode(encoded)
        else { throw CloudRelayTransportError.invalidFrame }
        if chunk.isEmpty { continue }
        return chunk
      case "end":
        await finish(reason: .done)
        return nil
      default:
        throw CloudRelayTransportError.invalidFrame
      }
    }
  }

  func finish(reason: CloudChannelCloseReason) async {
    guard !finished else { return }
    finished = true
    await channel.close(reason: reason)
  }
}
