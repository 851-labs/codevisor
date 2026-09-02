import Foundation

/// A handle to one open sealed channel. All I/O goes through the hosting
/// pipe's actor (the relay hub today, a direct socket tomorrow); the handle
/// just carries the id.
public final class CloudRelayChannel: Sendable {
  public let id: String
  private let host: any CloudChannelHosting

  init(id: String, host: any CloudChannelHosting) {
    self.id = id
    self.host = host
  }

  /// Seals and sends one JSON payload on the channel.
  @discardableResult
  public func sendJSON(_ value: some Encodable & Sendable) async throws -> Int {
    try await host.send(channelId: id, plaintext: JSONEncoder().encode(value))
  }

  /// Seals and sends raw plaintext bytes on the channel.
  @discardableResult
  public func send(plaintext: Data) async throws -> Int {
    try await host.send(channelId: id, plaintext: plaintext)
  }

  /// Grants the peer more receive budget after the local consumer has
  /// accepted bytes from a flow-controlled channel.
  public func grantCredit(bytes: Int) async throws {
    try await host.grantCredit(channelId: id, bytes: bytes)
  }

  /// Closes the channel toward the peer. The channel's `onClosed` callback
  /// does not fire for self-initiated closes.
  public func close(reason: CloudChannelCloseReason) async {
    await host.closeChannel(id, reason: reason)
  }
}
