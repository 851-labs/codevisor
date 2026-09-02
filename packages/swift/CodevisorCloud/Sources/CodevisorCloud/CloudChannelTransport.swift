import ACPKit
import Foundation

/// A pipe that carries end-to-end sealed channels to one machine. The cloud
/// relay (`CloudRelayEndpoint` over the account's hub connection) is
/// implementation #1; a direct LAN/tailnet socket is the planned #2. The
/// HTTP/WS tunnels and the loopback bridge depend only on this surface, so a
/// channel neither knows nor cares which pipe carries it — and a pipe's death
/// tears down only the channels IT carries (owners re-open from durable
/// cursors on whatever pipe is available next).
public protocol CloudChannelTransport: Sendable {
  /// The machine this transport reaches (stable cloud device id) — for
  /// logging and per-machine bookkeeping, never for routing decisions.
  var machineDeviceId: String { get }

  /// Opens an end-to-end encrypted channel. `onMessage` gets each decrypted
  /// inbound payload; `onClosed` fires once when the channel ends (with the
  /// peer's close reason, or nil on pipe loss). Both may be invoked before
  /// this returns. `compressed: true` negotiates prefix-framed payloads the
  /// machine may DEFLATE (see CloudDeflate).
  func openChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel

  /// Opens a raw channel whose owner explicitly grants receive credit and
  /// observes peer grants before sending. Credit is counted in ciphertext
  /// bytes, matching the wire format. `compressed: true` composes the same
  /// prefix framing as `openChannel` on top of the credit accounting.
  func openFlowControlledChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel
}

/// What an open channel handle needs from whichever pipe hosts it: seal-and-
/// send, credit grants, and close. `CloudHubConnection` is implementation #1.
protocol CloudChannelHosting: Actor {
  func send(channelId: String, plaintext: Data) throws -> Int
  func grantCredit(channelId: String, bytes: Int) throws
  func closeChannel(_ channelId: String, reason: CloudChannelCloseReason)
}

extension CloudHubConnection: CloudChannelHosting {}

/// One machine reachable over the cloud relay: which hub to go through and
/// the machine's pinned identity. The relay implementation of
/// `CloudChannelTransport`.
public struct CloudRelayEndpoint: Sendable, CloudChannelTransport {
  public let hub: CloudHubConnection
  public let machineDeviceId: String
  public let machinePublicKey: String

  public init(hub: CloudHubConnection, machineDeviceId: String, machinePublicKey: String) {
    self.hub = hub
    self.machineDeviceId = machineDeviceId
    self.machinePublicKey = machinePublicKey
  }

  public func openChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel {
    try await hub.openChannel(
      machineDeviceId: machineDeviceId,
      machinePublicKey: machinePublicKey,
      channelType: channelType,
      params: params,
      compressed: compressed,
      onMessage: onMessage,
      onClosed: onClosed
    )
  }

  public func openFlowControlledChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel {
    try await hub.openFlowControlledChannel(
      machineDeviceId: machineDeviceId,
      machinePublicKey: machinePublicKey,
      channelType: channelType,
      params: params,
      compressed: compressed,
      onMessage: onMessage,
      onCredit: onCredit,
      onClosed: onClosed
    )
  }
}
