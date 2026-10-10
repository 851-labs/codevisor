import Foundation

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
