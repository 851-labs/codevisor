import Foundation
import Network

/// One-request-per-connection HTTP listener. The handler runs on its own actor
/// (usually the main actor); this class only frames bytes and bounds them.
public final class RigHTTPServer: @unchecked Sendable {
  public struct Response: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
      self.status = status
      self.body = body
    }
    public static func json<T: Encodable>(_ status: Int, _ value: T) -> Response {
      Response(status: status, body: (try? RigJSON.encode(value)) ?? Data())
    }
    public static func error(_ status: Int, _ message: String) -> Response {
      .json(status, RigErrorBody(error: message))
    }
  }
  public typealias Handler = @Sendable (RigHTTPRequest) async -> Response

  private let listener: NWListener
  private let queue = DispatchQueue(label: "codevisor.rig.http")
  private let handler: Handler
  private let requestTimeoutSeconds: Double
  private let lock = NSLock()
  private var readyContinuation: CheckedContinuation<UInt16, any Error>?
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  /// `loopbackOnly` binds 127.0.0.1 (viewer control); otherwise all interfaces (host signaling).
  public init(
    port: UInt16, loopbackOnly: Bool, requestTimeoutSeconds: Double = 10, handler: @escaping Handler
  )
    throws
  {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw RigHTTPServerError.invalidPort(port) }
    if loopbackOnly {
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
      listener = try NWListener(using: parameters)
    } else {
      listener = try NWListener(using: parameters, on: nwPort)
    }
    self.handler = handler
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }

  /// Resolves with the bound port once the listener is ready; throws if it fails.
  public func start() async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { readyContinuation = continuation }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          let port = self.listener.port?.rawValue ?? 0
          self.lock.withLock {
            self.readyContinuation?.resume(returning: port); self.readyContinuation = nil
          }
        case .failed(let error):
          self.lock.withLock {
            self.readyContinuation?.resume(throwing: error); self.readyContinuation = nil
          }
        case .cancelled:
          self.lock.withLock {
            self.readyContinuation?.resume(throwing: CancellationError())
            self.readyContinuation = nil
          }
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.start(queue: queue)
    }
  }

  public func stop() {
    listener.cancel()
    let open = lock.withLock { connections.values.map { $0 } }
    for connection in open { connection.cancel() }
  }

  /// Wraps the per-connection timeout so it can travel through `` receive callbacks.
  private final class Timeout: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
  }

  private func accept(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    lock.withLock { connections[key] = connection }
    let timeout = Timeout(
      DispatchWorkItem { [weak self] in
        connection.cancel()
        self?.forget(key)
      })
    queue.asyncAfter(deadline: .now() + requestTimeoutSeconds, execute: timeout.item)
    connection.stateUpdateHandler = { [weak self] state in
      if case .cancelled = state { self?.forget(key) }
      if case .failed = state { self?.forget(key) }
    }
    connection.start(queue: queue)
    receive(on: connection, buffer: Data(), timeout: timeout)
  }

  private func forget(_ key: ObjectIdentifier) { lock.withLock { _ = connections.removeValue(forKey: key) } }

  private func receive(on connection: NWConnection, buffer: Data, timeout: Timeout) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let content { buffer.append(content) }
      switch RigHTTPCodec.parse(buffer) {
      case .complete(let request, _):
        timeout.cancel()
        Task {
          let response = await self.handler(request)
          self.send(RigHTTPCodec.response(status: response.status, body: response.body), on: connection)
        }
      case .invalid(let reason):
        timeout.cancel()
        self.send(
          RigHTTPCodec.response(status: 400, body: (try? RigJSON.encode(RigErrorBody(error: reason))) ?? Data()),
          on: connection)
      case .incomplete:
        if error != nil || isComplete || buffer.count > RigHTTPCodec.maximumHeaderBytes + RigHTTPCodec.maximumBodyBytes
        {
          timeout.cancel()
          connection.cancel()
        } else {
          self.receive(on: connection, buffer: buffer, timeout: timeout)
        }
      }
    }
  }

  private func send(_ data: Data, on connection: NWConnection) {
    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
  }
}

public enum RigHTTPServerError: Error, CustomStringConvertible {
  case invalidPort(UInt16)
  public var description: String {
    switch self {
    case .invalidPort(let port): return "invalid port \(port)"
    }
  }
}
