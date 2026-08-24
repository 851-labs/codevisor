import ACPKit
import Foundation

/// The direct-pipe implementation of `CloudChannelTransport` — pipe #2 beside
/// `CloudRelayEndpoint`. Channels opened here make one LAN hop straight to
/// the machine's `/v1/direct` listener.
public struct CloudDirectTransport: Sendable, CloudChannelTransport {
    public let connection: CloudDirectConnection

    public init(connection: CloudDirectConnection) {
        self.connection = connection
    }

    public var machineDeviceId: String { connection.machineDeviceId }

    public func openChannel(
        channelType: String,
        params: JSONValue?,
        compressed: Bool,
        onMessage: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        try await connection.openChannel(
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
        onMessage: @escaping @Sendable (Data, Int) -> Void,
        onCredit: @escaping @Sendable (Int) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        try await connection.openFlowControlledChannel(
            channelType: channelType,
            params: params,
            onMessage: onMessage,
            onCredit: onCredit,
            onClosed: onClosed
        )
    }
}

/// Chooses the pipe at channel-open time. Consumers (HTTP/WS tunnels, the
/// loopback bridge) hold ONE transport per machine for their whole life;
/// because every channel is ephemeral, each new open simply asks the provider
/// which pipe is best right now — a live verified direct pipe, else the
/// relay. No consumer ever migrates an open channel between pipes.
public struct SwitchingChannelTransport: Sendable, CloudChannelTransport {
    public let machineDeviceId: String
    private let provider: @Sendable () async -> any CloudChannelTransport

    public init(
        machineDeviceId: String,
        provider: @escaping @Sendable () async -> any CloudChannelTransport
    ) {
        self.machineDeviceId = machineDeviceId
        self.provider = provider
    }

    public func openChannel(
        channelType: String,
        params: JSONValue?,
        compressed: Bool,
        onMessage: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        try await provider().openChannel(
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
        onMessage: @escaping @Sendable (Data, Int) -> Void,
        onCredit: @escaping @Sendable (Int) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        try await provider().openFlowControlledChannel(
            channelType: channelType,
            params: params,
            onMessage: onMessage,
            onCredit: onCredit,
            onClosed: onClosed
        )
    }
}
