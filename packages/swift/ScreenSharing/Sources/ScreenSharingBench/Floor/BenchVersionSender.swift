public final class BenchVersionSender: Sendable {
  private static let receiveTimeout = Duration.milliseconds(100)

  public let target: BenchUDPAddress
  private let socket: BenchUDPSocket

  public init(target: BenchUDPAddress) throws {
    self.target = target
    socket = try BenchUDPSocket(receiveTimeout: Self.receiveTimeout)
  }

  public func send(_ message: BenchVersionMessage) throws {
    try socket.send(message.bytes, to: target)
  }
}
