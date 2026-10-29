public final class BenchVersionReceiver: Sendable {
  public let port: UInt16
  private let socket: BenchUDPSocket

  public init(port: UInt16, receiveTimeout: Duration) throws {
    socket = try BenchUDPSocket(port: port, receiveTimeout: receiveTimeout)
    self.port = socket.port
  }

  public func receive() throws -> BenchVersionMessage? {
    guard let datagram = try socket.receive() else { return nil }

    return BenchVersionMessage(bytes: datagram.bytes)
  }
}
