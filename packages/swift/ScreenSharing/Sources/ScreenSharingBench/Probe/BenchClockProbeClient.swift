import Synchronization

public final class BenchClockProbeClient: Sendable {
  public static let probesPerBurst = 16
  public static let defaultReplyTimeout = Duration.milliseconds(50)

  private let socket: BenchUDPSocket
  private let responder: BenchUDPAddress
  private let lastSequence = Atomic<UInt64>(0)
  private let failure = Mutex<(any Error)?>(nil)

  public init(responder: BenchUDPAddress, replyTimeout: Duration = defaultReplyTimeout) throws {
    socket = try BenchUDPSocket(receiveTimeout: replyTimeout)
    self.responder = responder
  }

  public var lastError: (any Error)? {
    failure.withLock { $0 }
  }

  public func burst(probes: Int = probesPerBurst) -> [BenchClockExchange] {
    (0..<probes).compactMap { _ in probe() }
  }

  private func probe() -> BenchClockExchange? {
    let sequence = lastSequence.add(1, ordering: .relaxed).newValue
    let request = BenchClockProbePacket.request(sequence: sequence, clientSendNs: BenchMachClock.nowNs())
    do {
      try socket.send(request.bytes, to: responder)
      return try reply(to: sequence)
    } catch {
      failure.withLock { $0 = error }
      return nil
    }
  }

  private func reply(to sequence: UInt64) throws -> BenchClockExchange? {
    while let datagram = try socket.receive() {
      guard let reply = BenchClockProbePacket(bytes: datagram.bytes), isReply(reply, to: sequence) else { continue }

      return reply.exchange(clientReceiveNs: datagram.receivedNs)
    }
    return nil
  }

  private func isReply(_ packet: BenchClockProbePacket, to sequence: UInt64) -> Bool {
    packet.kind == .reply && packet.sequence == sequence
  }
}
