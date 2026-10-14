import ACPKit
import CodevisorClient
import Foundation

public struct CloudRelayWebSocketTransport: ServerWebSocketTransport {
  private let endpoint: any CloudChannelTransport

  public init(endpoint: any CloudChannelTransport) {
    self.endpoint = endpoint
  }

  public func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    CloudRelayWebSocketConnection(endpoint: endpoint, request: request)
  }
}

final class CloudRelayWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
  private struct WsFrame: Codable {
    var kind: String
    var data: String
  }

  private struct Inbound {
    var message: ServerWebSocketMessage
    var credit: Int
  }

  private final class PartAccumulator: @unchecked Sendable {
    private var bytes = Data()

    func append(base64URL piece: String) -> Bool {
      guard let decoded = CloudChannelCrypto.base64URLDecode(piece) else { return false }
      bytes.append(decoded)
      return true
    }

    func finish(base64URL piece: String) -> Data? {
      guard let decoded = CloudChannelCrypto.base64URLDecode(piece) else {
        bytes.removeAll()
        return nil
      }
      var message = bytes
      message.append(decoded)
      bytes.removeAll()
      return message
    }
  }

  private final class ImmediateGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: CloudRelayChannel?
    private var pending = 0

    func attach(_ channel: CloudRelayChannel) {
      lock.withLock { self.channel = channel }
      flush()
    }

    func grant(_ bytes: Int) {
      lock.withLock { pending += bytes }
      flush()
    }

    private func flush() {
      let drained: (channel: CloudRelayChannel, bytes: Int)? = lock.withLock {
        guard let channel, pending > 0 else { return nil }
        defer { pending = 0 }
        return (channel, pending)
      }
      guard let drained else { return }
      Task { try? await drained.channel.grantCredit(bytes: drained.bytes) }
    }
  }

  private let lock = NSLock()
  private let openTask: Task<CloudRelayChannel, any Error>
  private let gate = CloudChannelCreditGate()
  private var iterator: AsyncThrowingStream<Inbound, any Error>.Iterator
  private let continuation: AsyncThrowingStream<Inbound, any Error>.Continuation
  private var cancelled = false
  private var unanswered = false
  private let answered = AnsweredFlag()

  private final class AnsweredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
  }

  init(endpoint: any CloudChannelTransport, request: URLRequest) {
    let (messages, continuation) = AsyncThrowingStream<Inbound, any Error>.makeStream()
    self.continuation = continuation
    iterator = messages.makeAsyncIterator()

    var path = "/"
    if let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    {
      path = components.path.isEmpty ? "/" : components.path
      if let query = components.query, !query.isEmpty {
        path += "?\(query)"
      }
    }
    let decoder = JSONDecoder()
    let pendingParts = PartAccumulator()
    let immediate = ImmediateGrants()
    let gate = gate
    let answered = answered
    openTask = Task {
      let channel = try await endpoint.openFlowControlledChannel(
        channelType: "ws",
        params: .object(["path": .string(path)]),
        compressed: true,
        onMessage: { data, sealedBytes in
          answered.set()
          guard let frame = try? decoder.decode(WsFrame.self, from: data) else {
            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
            return
          }
          switch frame.kind {
          case "text":
            continuation.yield(Inbound(message: .string(frame.data), credit: sealedBytes))
          case "binary":
            if let decoded = CloudChannelCrypto.base64URLDecode(frame.data) {
              continuation.yield(Inbound(message: .data(decoded), credit: sealedBytes))
            } else {
              continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
            }
          case "part":
            if pendingParts.append(base64URL: frame.data) {
              immediate.grant(sealedBytes)
            } else {
              continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
            }
          case "text-end":
            if let message = pendingParts.finish(base64URL: frame.data) {
              continuation.yield(
                Inbound(
                  message: .string(String(decoding: message, as: UTF8.self)),
                  credit: sealedBytes
                ))
            } else {
              continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
            }
          case "binary-end":
            if let message = pendingParts.finish(base64URL: frame.data) {
              continuation.yield(Inbound(message: .data(message), credit: sealedBytes))
            } else {
              continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
            }
          default:
            immediate.grant(sealedBytes)
          }
        },
        onCredit: { bytes in gate.add(bytes) },
        onClosed: { reason in
          gate.fail(CloudRelayTransportError.channelClosed(reason))
          if reason == .done {
            continuation.finish()
          } else {
            continuation.finish(throwing: CloudRelayTransportError.channelClosed(reason))
          }
        }
      )
      immediate.attach(channel)
      try await channel.grantCredit(bytes: CloudRelayProxy.initialCreditBytes)
      return channel
    }
  }

  func send(_ message: ServerWebSocketMessage) async throws {
    let channel = try await openTask.value
    let frame =
      switch message {
      case let .string(text):
        WsFrame(kind: "text", data: text)
      case let .data(data):
        WsFrame(kind: "binary", data: CloudChannelCrypto.base64URLEncode(data))
      }
    let payload = try JSONEncoder().encode(frame)
    try await gate.consume(
      CloudChannelCreditGate.sealedCost(plaintextBytes: payload.count, compressed: true))
    _ = try await channel.send(plaintext: payload)
  }

  func receive() async throws -> ServerWebSocketMessage {
    let channel = try await openTask.value
    guard let inbound = try await iterator.next() else {
      throw CloudRelayTransportError.channelClosed(.done)
    }
    try? await channel.grantCredit(bytes: inbound.credit)
    return inbound.message
  }

  func markUnanswered() {
    guard !answered.isSet else { return }
    lock.withLock { unanswered = true }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let (shouldClose, unanswered) = lock.withLock {
      let first = !cancelled
      cancelled = true
      return (first, self.unanswered)
    }
    guard shouldClose else { return }
    continuation.finish(throwing: CancellationError())
    gate.fail(CancellationError())
    openTask.cancel()
    let openTask = openTask
    Task {
      if let channel = try? await openTask.value {
        if unanswered { await channel.reportUnanswered() }
        await channel.close(reason: .done)
      }
    }
  }

  var closeCode: URLSessionWebSocketTask.CloseCode {
    .invalid
  }
}
