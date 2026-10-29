import Foundation
import Synchronization

public final class BenchClockProbeResponder: Sendable {
  private static let stopCheckInterval = Duration.milliseconds(100)
  private static let failureBackoffSeconds = 0.1

  public let port: UInt16
  private let socket: BenchUDPSocket
  private let isStopped = Atomic(false)
  private let answered = Atomic(0)
  private let lastAnsweredNs = Atomic<Int64>(0)
  private let failures = Atomic(0)
  private let failure = Mutex<(any Error)?>(nil)

  public init(port: UInt16 = 0) throws {
    socket = try BenchUDPSocket(port: port, receiveTimeout: Self.stopCheckInterval)
    self.port = socket.port
  }

  public var answeredProbes: Int {
    answered.load(ordering: .relaxed)
  }

  public var lastAnswerNs: Int64? {
    let last = lastAnsweredNs.load(ordering: .relaxed)
    return last == 0 ? nil : last
  }

  public func start() {
    let thread = Thread { [self] in serve() }
    thread.name = "Clock probe responder"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  public func stop() {
    isStopped.store(true, ordering: .relaxed)
  }

  public var failedReceivesAndReplies: Int {
    failures.load(ordering: .relaxed)
  }

  public var lastError: (any Error)? {
    failure.withLock { $0 }
  }

  private func serve() {
    while !isStopped.load(ordering: .relaxed) {
      do {
        guard let datagram = try socket.receive() else { continue }

        try answer(datagram)
      } catch {
        record(error)
      }
    }
  }

  private func record(_ error: any Error) {
    failures.add(1, ordering: .relaxed)
    failure.withLock { $0 = error }
    Thread.sleep(forTimeInterval: Self.failureBackoffSeconds)
  }

  private func answer(_ datagram: BenchUDPDatagram) throws {
    guard let request = BenchClockProbePacket(bytes: datagram.bytes), request.kind == .request else { return }

    let reply = request.reply(receivedNs: datagram.receivedNs, sentNs: BenchMachClock.nowNs())
    try socket.send(reply.bytes, to: datagram.sender)
    answered.add(1, ordering: .relaxed)
    lastAnsweredNs.store(BenchMachClock.nowNs(), ordering: .relaxed)
  }
}
