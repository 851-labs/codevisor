import ACPKit
import Foundation

/// A pipe that carries end-to-end sealed channels to one machine — today a
/// `CloudDirectTransport` over the peer-to-peer tunnel. The HTTP/WS channel
/// adapters and the loopback bridge depend only on this surface, so a
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
/// send, credit grants, and close (`CloudDirectConnection`).
protocol CloudChannelHosting: Actor {
  func send(channelId: String, plaintext: Data) throws -> Int
  func grantCredit(channelId: String, bytes: Int) throws
  func closeChannel(_ channelId: String, reason: CloudChannelCloseReason)
  /// The channel's owner gave up waiting for the machine's first frame.
  /// Call before `closeChannel`; hosts ignore channels that did receive
  /// traffic, and treat repeated silence as a broken pipe.
  func reportUnanswered(channelId: String)
}
