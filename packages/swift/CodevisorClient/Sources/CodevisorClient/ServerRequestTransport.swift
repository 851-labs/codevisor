import Foundation

public protocol ServerRequestTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

  func stream(
    for request: URLRequest
  ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)

  func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
}

extension ServerRequestTransport {
  public func upload(
    for request: URLRequest,
    fromFile fileURL: URL
  ) async throws -> (Data, HTTPURLResponse) {
    var request = request
    request.httpBody = try Data(contentsOf: fileURL)
    return try await data(for: request)
  }

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

public enum ServerWebSocketMessage: Sendable, Equatable {
  case data(Data)
  case string(String)
}

public protocol ServerWebSocketConnecting: AnyObject, Sendable {
  func send(_ message: ServerWebSocketMessage) async throws
  func receive() async throws -> ServerWebSocketMessage
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
  var closeCode: URLSessionWebSocketTask.CloseCode { get }
  func markUnanswered()
}

extension ServerWebSocketConnecting {
  public func markUnanswered() {}
}

public protocol ServerWebSocketTransport: Sendable {
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting
}

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

public final class URLSessionWebSocketConnection: ServerWebSocketConnecting {
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
