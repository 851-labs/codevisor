import Foundation

public struct MachineUnreachableError: LocalizedError, Sendable {
  public let machineId: String

  public init(machineId: String) {
    self.machineId = machineId
  }

  public var errorDescription: String? {
    "This machine isn't reachable right now. Check its connection and try again."
  }
}

struct UnreachableRequestTransport: ServerRequestTransport {
  let machineId: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw MachineUnreachableError(machineId: machineId)
  }

  func stream(
    for request: URLRequest
  ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    throw MachineUnreachableError(machineId: machineId)
  }

  func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
    throw MachineUnreachableError(machineId: machineId)
  }
}

struct UnreachableWebSocketTransport: ServerWebSocketTransport {
  let machineId: String

  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    UnreachableWebSocketConnection(machineId: machineId)
  }
}

private final class UnreachableWebSocketConnection: ServerWebSocketConnecting {
  private let machineId: String

  init(machineId: String) {
    self.machineId = machineId
  }

  func send(_ message: ServerWebSocketMessage) async throws {
    throw MachineUnreachableError(machineId: machineId)
  }

  func receive() async throws -> ServerWebSocketMessage {
    throw MachineUnreachableError(machineId: machineId)
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

  var closeCode: URLSessionWebSocketTask.CloseCode { .abnormalClosure }
}

extension CodevisorServerConfig {
  public static func unreachable(machineId: String) -> CodevisorServerConfig {
    CodevisorServerConfig(
      baseURL: URL(string: "http://unreachable.invalid")!,
      bearerToken: nil,
      requestTransport: UnreachableRequestTransport(machineId: machineId),
      webSocketTransport: UnreachableWebSocketTransport(machineId: machineId)
    )
  }
}
