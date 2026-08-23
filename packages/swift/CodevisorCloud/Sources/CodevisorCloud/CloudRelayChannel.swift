import Foundation

/// A handle to one open relay channel. All I/O goes through the hub actor;
/// the handle just carries the id.
public final class CloudRelayChannel: Sendable {
    public let id: String
    private let hub: CloudHubConnection

    init(id: String, hub: CloudHubConnection) {
        self.id = id
        self.hub = hub
    }

    /// Seals and sends one JSON payload on the channel.
    @discardableResult
    public func sendJSON(_ value: some Encodable & Sendable) async throws -> Int {
        try await hub.send(channelId: id, plaintext: JSONEncoder().encode(value))
    }

    /// Seals and sends raw plaintext bytes on the channel.
    @discardableResult
    public func send(plaintext: Data) async throws -> Int {
        try await hub.send(channelId: id, plaintext: plaintext)
    }

    /// Grants the peer more receive budget after the local consumer has
    /// accepted bytes from a flow-controlled channel.
    public func grantCredit(bytes: Int) async throws {
        try await hub.grantCredit(channelId: id, bytes: bytes)
    }

    /// Closes the channel toward the peer. The channel's `onClosed` callback
    /// does not fire for self-initiated closes.
    public func close(reason: CloudChannelCloseReason) async {
        await hub.closeChannel(id, reason: reason)
    }
}
