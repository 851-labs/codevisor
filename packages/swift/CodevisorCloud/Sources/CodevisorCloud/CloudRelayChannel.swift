import Foundation

public final class CloudRelayChannel: Sendable {
  public let id: String
  private let host: any CloudChannelHosting

  init(id: String, host: any CloudChannelHosting) {
    self.id = id
    self.host = host
  }

  @discardableResult
  public func send(plaintext: Data) async throws -> Int {
    try await host.send(channelId: id, plaintext: plaintext)
  }

  public func grantCredit(bytes: Int) async throws {
    try await host.grantCredit(channelId: id, bytes: bytes)
  }

  public func reportUnanswered() async {
    await host.reportUnanswered(channelId: id)
  }

  public func close(reason: CloudChannelCloseReason) async {
    await host.closeChannel(id, reason: reason)
  }
}
