import Foundation
import Network

public protocol RFBTransport: Sendable {
  var name: String { get }
  func read(maximum: Int) async throws -> [UInt8]
  func write(_ bytes: [UInt8]) async throws
  func close()
}

extension RFBTransport {
  public var name: String { "Stream" }
}

public final class RFBNetworkTransport: RFBTransport, @unchecked Sendable {
  public var name: String { "TCP" }
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.851labs.Codevisor.rfb")
  private let lock = NSLock()
  private var streamEnded = false

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
    guard !lock.withLock({ streamEnded }) else { return [] }
    return try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, complete, error in
        if complete { self.markStreamEnded() }
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
            continuation.resume(throwing: Self.writeFailure(error))
          } else {
            continuation.resume()
          }
        })
    }
  }

  public func close() { connection.cancel() }

  private func markStreamEnded() { lock.withLock { streamEnded = true } }

  private static let peerGoneCodes: Set<POSIXErrorCode> = [.EPIPE, .ECONNRESET, .ENOTCONN]

  private static func writeFailure(_ error: NWError) -> RFBError {
    guard case .posix(let code) = error, peerGoneCodes.contains(code) else { return .transport(describe(error)) }
    return .connectionClosed
  }

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
