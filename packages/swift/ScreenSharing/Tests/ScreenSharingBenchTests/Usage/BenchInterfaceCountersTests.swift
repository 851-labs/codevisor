import Testing

@testable import ScreenSharingBench

struct BenchInterfaceCountersTests {
  @Test func loopbackCountersIncludeTheBytesSentOverLoopback() throws {
    let receiver = try BenchUDPSocket(receiveTimeout: .seconds(10))
    let sender = try BenchUDPSocket(receiveTimeout: .seconds(10))
    let payload = [UInt8](repeating: 0xA5, count: 400)
    let before = try BenchInterfaceCounters.sample(interface: "lo0")

    for _ in 0..<10 { try sender.send(payload, to: BenchUDPAddress(host: "127.0.0.1", port: receiver.port)) }
    let after = try BenchInterfaceCounters.sample(interface: "lo0")

    #expect(after.sentBytes - before.sentBytes >= 4_000)
    #expect(after.receivedBytes - before.receivedBytes >= 4_000)
  }

  @Test func rateIsMegabitsPerSecondInEachDirection() throws {
    let earlier = BenchInterfaceCounters(sampledNs: 0, receivedBytes: 1_000, sentBytes: 2_000)
    let later = BenchInterfaceCounters(sampledNs: 2_000_000_000, receivedBytes: 250_001_000, sentBytes: 2_502_000)

    let rate = try #require(BenchInterfaceRate(from: earlier, to: later))

    #expect(abs(rate.receivedMbps - 1_000) < 1e-9)
    #expect(abs(rate.sentMbps - 10) < 1e-9)
  }
}
