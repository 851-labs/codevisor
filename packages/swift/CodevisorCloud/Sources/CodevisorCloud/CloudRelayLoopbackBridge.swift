import CodevisorClient
import Foundation
import Network

/// A real local address for one cloud machine. Every accepted loopback TCP
/// connection becomes one end-to-end encrypted, flow-controlled byte stream
/// to the machine's own Codevisor listener.
///
/// The bridge does not parse HTTP or WebSocket traffic. Request streaming,
/// chunked responses, MJPEG, upgrades, keep-alive, half-closes, and any future
/// protocol layered on TCP therefore retain their original wire semantics.
public final class CloudRelayLoopbackBridge: @unchecked Sendable {
  public enum BridgeError: Error, Sendable {
    case alreadyStarted
    case stopped
  }

  static let channelType = "byte-stream"
  static let service = "codevisor-loopback"
  static let protocolVersion = 1
  static let maximumChunkBytes = 64 * 1024
  static let initialCreditBytes = 1024 * 1024

  private let endpoint: any CloudChannelTransport
  private let queue = DispatchQueue(label: "com.codevisor.cloud-loopback-bridge")
  private let lock = NSLock()
  private var listener: NWListener?
  private var stopped = false
  private var connections: [ObjectIdentifier: LoopbackConnection] = [:]
  private var listeningPort: UInt16?
  private var startup: CheckedContinuation<UInt16, any Error>?
  private let onStateChange: @Sendable () -> Void
  public var port: UInt16? { lock.withLock { listeningPort } }
  public var isStopped: Bool { lock.withLock { stopped } }

  public init(
    endpoint: any CloudChannelTransport,
    onStateChange: @escaping @Sendable () -> Void = {}
  ) {
    self.endpoint = endpoint
    self.onStateChange = onStateChange
  }

  /// Starts a loopback-only listener on an ephemeral port.
  public func start() async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    try lock.withLock {
      guard !stopped else { throw BridgeError.stopped }
      guard self.listener == nil else { throw BridgeError.alreadyStarted }
      self.listener = listener
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.adopt(connection)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let accepted = lock.withLock {
        guard !stopped else { return false }
        startup = continuation
        return true
      }
      guard accepted else {
        listener.cancel()
        continuation.resume(throwing: BridgeError.stopped)
        return
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        self?.listenerStateChanged(state, port: listener?.port?.rawValue)
      }
      listener.start(queue: queue)
    }
  }

  // Observe the entire listener lifetime, including failure after start()
  // returned. Never let a late ready callback resurrect a stopped bridge.
  func listenerStateChanged(_ state: NWListener.State, port: UInt16?) {
    switch state {
    case .ready:
      guard let port else { finish(throwing: BridgeError.stopped); return }
      let result = lock.withLock { () -> (Bool, CheckedContinuation<UInt16, any Error>?) in
        guard !stopped else { return (false, nil) }
        listeningPort = port
        let pending = startup
        startup = nil
        return (true, pending)
      }
      guard result.0 else { return }
      result.1?.resume(returning: port)
      onStateChange()
    case .waiting:
      lock.withLock { listeningPort = nil }
      onStateChange()
    case let .failed(error):
      Log.cloud.error("Cloud loopback listener failed: \(String(describing: error), privacy: .public)")
      finish(throwing: error)
    case .cancelled:
      finish(throwing: BridgeError.stopped)
    default: break
    }
  }

  /// Stops listening and tears down every active tunnel.
  public func stop() {
    finish(throwing: BridgeError.stopped)
  }

  private func finish(throwing error: any Error) {
    let result = lock.withLock { () -> (NWListener?, [LoopbackConnection], CheckedContinuation<UInt16, any Error>?)? in
      guard !stopped else { return nil }
      stopped = true
      listeningPort = nil
      let result = (listener, Array(connections.values), startup)
      self.listener = nil
      startup = nil
      connections.removeAll()
      return result
    }
    guard let (listener, open, pending) = result else { return }
    listener?.cancel()
    for connection in open { connection.cancel() }
    pending?.resume(throwing: error)
    onStateChange()
  }

  private func adopt(_ connection: NWConnection) {
    let handler = LoopbackConnection(connection: connection, endpoint: endpoint, queue: queue)
    let id = ObjectIdentifier(handler)
    let accepted = lock.withLock {
      guard !stopped else { return false }
      connections[id] = handler
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }
    Task { [weak self] in
      await handler.run()
      self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
    }
  }

  /// Raw ChaCha20-Poly1305 box size: plaintext + 16-byte tag (the box
  /// travels as raw bytes — no encoding expansion).
  static func sealedByteCount(forPlaintextBytes count: Int) -> Int {
    precondition(count >= 0)
    return count + 16
  }

}

// MARK: - One accepted connection

private final class LoopbackConnection: @unchecked Sendable {
  private struct RelayChunk: Sendable {
    var data: Data
    var sealedBytes: Int
  }

  private enum TunnelError: Error {
    case relayClosed
    case creditOverflow
    case invalidCiphertextCost
  }

  private let connection: NWConnection
  private let endpoint: any CloudChannelTransport
  private let queue: DispatchQueue

  init(connection: NWConnection, endpoint: any CloudChannelTransport, queue: DispatchQueue) {
    self.connection = connection
    self.endpoint = endpoint
    self.queue = queue
  }

  func cancel() {
    connection.cancel()
  }

  func run() async {
    connection.start(queue: queue)
    defer { connection.cancel() }

    let (inbound, inboundContinuation) = AsyncStream<RelayChunk>.makeStream()
    let (credits, creditContinuation) = AsyncStream<Int>.makeStream()
    let channel: CloudRelayChannel
    do {
      channel = try await endpoint.openFlowControlledChannel(
        channelType: CloudRelayLoopbackBridge.channelType,
        params: .object([
          "service": .string(CloudRelayLoopbackBridge.service),
          "version": .number(Double(CloudRelayLoopbackBridge.protocolVersion)),
        ]),
        compressed: false,
        onMessage: { data, sealedBytes in
          inboundContinuation.yield(RelayChunk(data: data, sealedBytes: sealedBytes))
        },
        onCredit: { bytes in
          creditContinuation.yield(bytes)
        },
        onClosed: { _ in
          inboundContinuation.finish()
          creditContinuation.finish()
        }
      )
    } catch {
      Log.cloud.error("Cloud byte tunnel could not open: \(String(describing: error), privacy: .public)")
      inboundContinuation.finish()
      creditContinuation.finish()
      return
    }

    do {
      try await channel.grantCredit(bytes: CloudRelayLoopbackBridge.initialCreditBytes)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.copyClientToMachine(channel: channel, credits: credits) }
        group.addTask { try await self.copyMachineToClient(channel: channel, inbound: inbound) }
        do {
          while try await group.next() != nil {}
        } catch {
          // Cancellation alone does not wake an outstanding
          // NWConnection.receive; cancel the socket before the task
          // group waits for its sibling to unwind.
          connection.cancel()
          group.cancelAll()
          throw error
        }
      }
      await channel.close(reason: .done)
    } catch {
      await channel.close(reason: .rejected)
      Log.cloud.debug("Cloud byte tunnel ended: \(String(describing: error), privacy: .public)")
    }
    inboundContinuation.finish()
    creditContinuation.finish()
  }

  /// Local TCP → relay. Reading pauses before each chunk until the peer has
  /// granted enough ciphertext budget for the largest possible receive.
  private func copyClientToMachine(
    channel: CloudRelayChannel,
    credits: AsyncStream<Int>
  ) async throws {
    var available = 0
    var iterator = credits.makeAsyncIterator()
    let maximumCost = CloudRelayLoopbackBridge.sealedByteCount(
      forPlaintextBytes: CloudRelayLoopbackBridge.maximumChunkBytes
    )
    while true {
      try await fillCredit(&available, required: maximumCost, from: &iterator)
      let (data, complete) = try await receiveChunk()
      if let data, !data.isEmpty {
        let cost = try await channel.send(plaintext: data)
        guard
          cost
            == CloudRelayLoopbackBridge.sealedByteCount(
              forPlaintextBytes: data.count
            ),
          cost <= available
        else { throw TunnelError.invalidCiphertextCost }
        available -= cost
      }
      if complete {
        let finCost = CloudRelayLoopbackBridge.sealedByteCount(forPlaintextBytes: 0)
        try await fillCredit(&available, required: finCost, from: &iterator)
        let actualCost = try await channel.send(plaintext: Data())
        guard actualCost == finCost, actualCost <= available else {
          throw TunnelError.invalidCiphertextCost
        }
        return
      }
    }
  }

  /// Relay → local TCP. Credit is returned only after Network.framework has
  /// accepted each chunk, propagating local backpressure across the relay.
  private func copyMachineToClient(
    channel: CloudRelayChannel,
    inbound: AsyncStream<RelayChunk>
  ) async throws {
    for await chunk in inbound {
      if chunk.data.isEmpty {
        try await send(Data(), isComplete: true)
        try await channel.grantCredit(bytes: chunk.sealedBytes)
        return
      }
      try await send(chunk.data)
      try await channel.grantCredit(bytes: chunk.sealedBytes)
    }
    throw TunnelError.relayClosed
  }

  private func fillCredit(
    _ available: inout Int,
    required: Int,
    from iterator: inout AsyncStream<Int>.Iterator
  ) async throws {
    while available < required {
      guard let grant = await iterator.next(), grant > 0 else {
        throw TunnelError.relayClosed
      }
      guard available <= Int.max - grant else { throw TunnelError.creditOverflow }
      available += grant
    }
  }

  private func receiveChunk() async throws -> (Data?, Bool) {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(
        minimumIncompleteLength: 1,
        maximumLength: CloudRelayLoopbackBridge.maximumChunkBytes
      ) { data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: (data, isComplete))
        }
      }
    }
  }

  private func send(_ data: Data, isComplete: Bool = false) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: isComplete && data.isEmpty ? nil : data,
        contentContext: isComplete ? .finalMessage : .defaultMessage,
        isComplete: isComplete,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      )
    }
  }
}
