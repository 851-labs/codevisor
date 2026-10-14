import ACPKit
import Foundation

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
    compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel {
    try await connection.openFlowControlledChannel(
      channelType: channelType,
      params: params,
      compressed: compressed,
      onMessage: onMessage,
      onCredit: onCredit,
      onClosed: onClosed
    )
  }
}

public struct SwitchingChannelTransport: Sendable, CloudChannelTransport {
  public let machineDeviceId: String
  private let provider: @Sendable () async throws -> any CloudChannelTransport

  public init(
    machineDeviceId: String,
    provider: @escaping @Sendable () async throws -> any CloudChannelTransport
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
    compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel {
    try await provider().openFlowControlledChannel(
      channelType: channelType,
      params: params,
      compressed: compressed,
      onMessage: onMessage,
      onCredit: onCredit,
      onClosed: onClosed
    )
  }
}
