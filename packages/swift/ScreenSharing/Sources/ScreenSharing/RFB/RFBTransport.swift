import Foundation
import Network

/// A byte stream to a VNC server. Reads return between one and `maximum`
/// bytes, or nothing once the peer has closed. `close()` is idempotent and
/// fails every pending or later read and write.
public protocol RFBTransport: Sendable {
  /// What carries the bytes, for diagnostics ("TCP", "WebSocket").
  var name: String { get }
  func read(maximum: Int) async throws -> [UInt8]
  func write(_ bytes: [UInt8]) async throws
  func close()
}

extension RFBTransport {
  public var name: String { "Stream" }
}

/// TCP through Network.framework. `connect` resolves and waits for the
/// connection to be ready or to fail; a `waiting` state (no route, refused
/// and retrying) fails fast, since the viewer owns retrying.
public final class RFBNetworkTransport: RFBTransport, @unchecked Sendable {
  public var name: String { "TCP" }
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.851labs.Codevisor.rfb")

  public static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> RFBNetworkTransport
  {
    guard let port = NWEndpoint.Port(rawValue: port) else { throw RFBError.transport("Invalid port.") }
    let options = NWProtocolTCP.Options()
    options.connectionTimeout = Int(timeout)
    options.noDelay = true
    let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: options))
    let transport = RFBNetworkTransport(connection: connection)
    try await transport.waitUntilReady()
    return transport
  }

  /// An already-accepted connection (the loopback server).
  package init(connection: NWConnection) {
    self.connection = connection
  }

  package func waitUntilReady() async throws {
    let settled = RFBOnce()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.stateUpdateHandler = { [connection] state in
        switch state {
        case .ready:
          if settled.claim() { continuation.resume() }
        case .failed(let error), .waiting(let error):
          if settled.claim() {
            connection.cancel()
            continuation.resume(throwing: RFBError.transport(Self.describe(error)))
          }
        case .cancelled:
          if settled.claim() { continuation.resume(throwing: RFBError.connectionClosed) }
        default: break
        }
      }
      connection.start(queue: queue)
    }
    connection.stateUpdateHandler = nil
  }

  public func read(maximum: Int) async throws -> [UInt8] {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, complete, error in
        if let data, !data.isEmpty {
          continuation.resume(returning: [UInt8](data))
        } else if let error, !complete {
          continuation.resume(throwing: RFBError.transport(Self.describe(error)))
        } else {
          continuation.resume(returning: [])
        }
      }
    }
  }

  public func write(_ bytes: [UInt8]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: Data(bytes),
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: RFBError.transport(Self.describe(error)))
          } else {
            continuation.resume()
          }
        })
    }
  }

  public func close() { connection.cancel() }

  private static func describe(_ error: NWError) -> String {
    switch error {
    case .posix(let code):
      switch code {
      case .ECONNREFUSED: "The VNC server refused the connection."
      case .ETIMEDOUT: "The VNC server did not answer in time."
      case .EHOSTUNREACH, .ENETUNREACH: "The VNC server cannot be reached."
      case .ECANCELED: "The connection was closed."
      default: "Connection error (\(code.rawValue))."
      }
    case .dns: "The VNC server's address could not be resolved."
    default: "Connection error: \(error.localizedDescription)"
    }
  }

}

/// A continuation guard: the first `claim()` wins, later state callbacks are ignored.
package final class RFBOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  package init() {}
  package func claim() -> Bool {
    lock.withLock {
      defer { done = true }
      return !done
    }
  }
}
