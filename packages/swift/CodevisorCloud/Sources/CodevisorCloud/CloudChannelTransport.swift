import ACPKit
import Foundation

public protocol CloudChannelTransport: Sendable {
  var machineDeviceId: String { get }

  func openChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel

  func openFlowControlledChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel
}

protocol CloudChannelHosting: Actor {
  func send(channelId: String, plaintext: Data) throws -> Int
  func grantCredit(channelId: String, bytes: Int) throws
  func closeChannel(_ channelId: String, reason: CloudChannelCloseReason)
  func reportUnanswered(channelId: String)
}
