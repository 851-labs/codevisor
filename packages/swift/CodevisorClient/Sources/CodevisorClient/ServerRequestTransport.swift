import Foundation

// MARK: - Transport seams

/// How a server client dispatches one HTTP request. The default is a plain
/// URLSession; cloud machines swap in a relay-backed transport that tunnels
/// the same requests through an end-to-end encrypted channel.
public protocol ServerRequestTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

  /// Streams the response body instead of buffering it: the head arrives
  /// first, then chunks as the transport produces them. Transports with a
  /// real streaming path (the cloud relay) pace the wire by consumer pulls;
  /// everything else falls back to the buffered default.
  func stream(
    for request: URLRequest
  ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)

  /// Sends `fileURL`'s contents as the request body without loading the
  /// file into memory, buffering the (small) response.
  func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
}

extension ServerRequestTransport {
  /// Default for fakes: reads the file into the body. Real transports
  /// stream it instead.
  public func upload(
    for request: URLRequest,
    fromFile fileURL: URL
  ) async throws -> (Data, HTTPURLResponse) {
    var request = request
    request.httpBody = try Data(contentsOf: fileURL)
    return try await data(for: request)
  }

  /// Default: buffer via `data(for:)` and yield the body as one chunk.
  public func stream(
    for request: URLRequest
  ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    let (data, response) = try await self.data(for: request)
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    if !data.isEmpty {
      continuation.yield(data)
    }
    continuation.finish()
    return (response, stream)
  }
}

/// URLSession-backed default request transport.
public struct URLSessionRequestTransport: ServerRequestTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CodevisorServerClientError.invalidResponse
    }
    return (data, httpResponse)
  }

  public func upload(
    for request: URLRequest,
    fromFile fileURL: URL
  ) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.upload(for: request, fromFile: fileURL)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CodevisorServerClientError.invalidResponse
    }
    return (data, httpResponse)
  }
}

/// A WebSocket message independent of URLSessionWebSocketTask, so relay-backed
/// and fake connections don't need Foundation's task types.
public enum ServerWebSocketMessage: Sendable, Equatable {
  case data(Data)
  case string(String)
}

/// One live WebSocket connection (already resumed). `receive` throws when the
/// connection dies — callers treat that as a disconnect and reconnect.
public protocol ServerWebSocketConnecting: AnyObject, Sendable {
  func send(_ message: ServerWebSocketMessage) async throws
  func receive() async throws -> ServerWebSocketMessage
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
  /// The server-sent close code once the connection has closed, `.invalid`
  /// while it hasn't.
  var closeCode: URLSessionWebSocketTask.CloseCode { get }
  /// The caller is abandoning this connection because the peer never
  /// answered in time. Call before `cancel`; transports that multiplex over
  /// a shared pipe use it to detect a pipe that silently drops new
  /// connections. Plain sockets have nothing to report.
  func markUnanswered()
}

extension ServerWebSocketConnecting {
  public func markUnanswered() {}
}

/// How a server client opens WebSocket connections — the socket sibling of
/// `ServerRequestTransport`.
public protocol ServerWebSocketTransport: Sendable {
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting
}

/// URLSessionWebSocketTask-backed default WebSocket transport.
public struct URLSessionWebSocketTransport: ServerWebSocketTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = maximumMessageSize
    task.resume()
    return URLSessionWebSocketConnection(task: task)
  }
}

/// Thin adapter putting a URLSessionWebSocketTask behind the seam.
public final class URLSessionWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
  private let task: URLSessionWebSocketTask

  public init(task: URLSessionWebSocketTask) {
    self.task = task
  }

  public func send(_ message: ServerWebSocketMessage) async throws {
    switch message {
    case let .data(data):
      try await task.send(.data(data))
    case let .string(text):
      try await task.send(.string(text))
    }
  }

  public func receive() async throws -> ServerWebSocketMessage {
    switch try await task.receive() {
    case let .data(data):
      return .data(data)
    case let .string(text):
      return .string(text)
    @unknown default:
      throw CodevisorServerClientError.invalidResponse
    }
  }

  public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    task.cancel(with: closeCode, reason: reason)
  }

  public var closeCode: URLSessionWebSocketTask.CloseCode {
    task.closeCode
  }
}
