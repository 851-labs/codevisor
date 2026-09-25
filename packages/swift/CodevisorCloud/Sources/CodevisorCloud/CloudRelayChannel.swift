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

  /// Tells the hosting pipe the owner gave up waiting for the machine to
  /// answer. Call before `close(reason:)`.
  public func reportUnanswered() async {
    await host.reportUnanswered(channelId: id)
  }

  /// Closes the channel toward the peer. The channel's `onClosed` callback
  /// does not fire for self-initiated closes.
  public func close(reason: CloudChannelCloseReason) async {
    await host.closeChannel(id, reason: reason)
  }
}
