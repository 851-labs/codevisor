import Foundation
import Testing

@testable import ScreenSharingBench

struct BenchClockProbeTests {
  private static let deadlockGuard = Duration.seconds(10)

  @Test func aBurstAgainstALiveResponderTimesEveryProbeInCausalOrder() throws {
    let responder = try BenchClockProbeResponder()
    responder.start()
    defer { responder.stop() }
    let client = try BenchClockProbeClient(
      responder: BenchUDPAddress(host: "127.0.0.1", port: responder.port), replyTimeout: Self.deadlockGuard)

    let exchanges = client.burst(probes: 4)

    #expect(exchanges.count == 4)
    for exchange in exchanges {
      #expect(exchange.localSendNs <= exchange.remoteReceiveNs)
      #expect(exchange.remoteReceiveNs <= exchange.remoteSendNs)
      #expect(exchange.remoteSendNs <= exchange.localReceiveNs)
    }
  }

  @Test func aLateReplyToAnEarlierProbeIsNotTakenForTheCurrentOne() throws {
    let responder = try BenchUDPSocket(receiveTimeout: Self.deadlockGuard)
    let client = try BenchClockProbeClient(
      responder: BenchUDPAddress(host: "127.0.0.1", port: responder.port), replyTimeout: Self.deadlockGuard)
    let stale = BenchClockProbePacket.request(sequence: 0, clientSendNs: 0).reply(receivedNs: 1, sentNs: 2)
    let answering = Thread {
      guard let datagram = try? responder.receive(), let request = BenchClockProbePacket(bytes: datagram.bytes) else {
        return
      }
      try? responder.send(stale.bytes, to: datagram.sender)
      try? responder.send(request.reply(receivedNs: 10, sentNs: 20).bytes, to: datagram.sender)
    }
    answering.start()

    let exchanges = client.burst(probes: 1)

    #expect(exchanges.map(\.remoteReceiveNs) == [10])
  }
}
