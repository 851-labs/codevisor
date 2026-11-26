import Darwin
import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct LoopbackRelayTests {
  private static let delayMs = 5.0
  private static let deadlockGuardMs: Int32 = 2_000

  @Test(arguments: [RelayDirection.media, .feedback])
  func aDelayedPacketLeavesWithoutWaitingForOtherTraffic(_ direction: RelayDirection) throws {
    let relay = try LoopbackRelay(
      conditions: BenchNetworkConditions(id: "delayed", delayMs: Self.delayMs), seed: 1,
      originNs: BenchMachClock.nowNs())
    defer { relay.close() }
    let host = try RelaySocket()
    defer { host.close() }
    let viewer = try RelaySocket()
    defer { viewer.close() }
    relay.connect(host: try Self.loopback(host.port), viewer: try Self.loopback(viewer.port))
    let sender = direction == .media ? host : viewer
    let receiver = direction == .media ? viewer : host
    let entrance = direction == .media ? relay.viewerFacing : relay.hostFacing

    let sentNs = BenchMachClock.nowNs()
    #expect(sender.send([7, 11], to: try Self.loopback(entrance.port)))
    let arrived = Self.waitUntilReadable(receiver)
    let elapsedMs = Double(BenchMachClock.nowNs() - sentNs) / 1e6

    #expect(arrived, "the relay held the packet until another one came")
    #expect(receiver.receive()?.bytes == [7, 11])
    #expect(elapsedMs >= Self.delayMs)
  }

  private static func loopback(_ port: UInt16) throws -> BenchUDPAddress {
    try BenchUDPAddress(host: "127.0.0.1", port: port)
  }

  private static func waitUntilReadable(_ socket: RelaySocket) -> Bool {
    var descriptor = pollfd(fd: socket.descriptor, events: Int16(POLLIN), revents: 0)
    var ready = poll(&descriptor, 1, deadlockGuardMs)
    while ready == -1, errno == EINTR { ready = poll(&descriptor, 1, deadlockGuardMs) }
    return ready == 1
  }
}
