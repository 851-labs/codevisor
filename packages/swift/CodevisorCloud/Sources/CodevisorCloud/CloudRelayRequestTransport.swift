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
      "The request to the machine timed out."
    }
  }
}

enum CloudRelayProxy {
  static let initialCreditBytes = 1024 * 1024
}

public struct CloudRelayRequestTransport: ServerRequestTransport {
  public static let chunkSize = 262_144
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

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let requestTimeout = timeout(for: request)
    return try await raced(expiry: { [sleep] in try await sleep(requestTimeout) }) { deadline in
      let (response, source) = try await performStream(
        request, body: .data(request.httpBody), deadline: deadline)
      return try await Self.collect(response, source)
    }
  }

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

  static let urlRequestDefaultTimeout: TimeInterval = 60

  private func timeout(for request: URLRequest) -> Duration {
    request.timeoutInterval == Self.urlRequestDefaultTimeout
      ? timeout : .seconds(request.timeoutInterval)
  }

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

  final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func markExpired() { lock.withLock { expired = true } }
    var hasExpired: Bool { lock.withLock { expired } }
  }

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
    let (url, params) = try requestParameters(for: request)

    let (frames, continuation) = AsyncThrowingStream<WireFrame, any Error>.makeStream()
    let gate = CloudChannelCreditGate()
    let decoder = JSONDecoder()
    let channel = try await openHTTPChannel(
      params: params, body: body, gate: gate, decoder: decoder, continuation: continuation)
    let source = HttpResponseSource(channel: channel, frames: frames)
    do {
      try await channel.grantCredit(bytes: CloudRelayProxy.initialCreditBytes)
      try await sendRequestBody(body, channel: channel, gate: gate)
      let response = try await source.readHead(url: url)
      return (response, source)
    } catch {
      if deadline.hasExpired { await channel.reportUnanswered() }
      await source.finish(reason: .done)
      throw error
    }
  }

  private func requestParameters(for request: URLRequest) throws -> (URL, JSONValue) {
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
    return (url, params)
  }

  private func openHTTPChannel(
    params: JSONValue,
    body: RequestBody,
    gate: CloudChannelCreditGate,
    decoder: JSONDecoder,
    continuation: AsyncThrowingStream<WireFrame, any Error>.Continuation
  ) async throws -> CloudRelayChannel {
    return try await endpoint.openFlowControlledChannel(
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
  }

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
      watchdog.freeze()
    }
  }
}
