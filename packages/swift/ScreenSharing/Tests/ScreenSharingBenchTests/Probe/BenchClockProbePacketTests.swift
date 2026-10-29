import ScreenSharingBench
import Testing

struct BenchClockProbePacketTests {
  @Test func aRequestHasTheDocumentedWireFormat() {
    let header: [UInt8] = Array("CVCP".utf8) + [1, 1, 0, 0]
    let sequence: [UInt8] = [0, 0, 0, 0, 0, 0, 0x01, 0x02]
    let clientSendNs: [UInt8] = [0, 0, 0, 0, 0x0A, 0x0B, 0x0C, 0x0D]
    let unsetResponderTimes = [UInt8](repeating: 0, count: 16)

    let request = BenchClockProbePacket.request(sequence: 0x0102, clientSendNs: 0x0A0B_0C0D)

    #expect(request.bytes == header + sequence + clientSendNs + unsetResponderTimes)
  }

  @Test func aDecodedReplyCarriesAllFourTimestampsOfTheExchange() throws {
    let request = try #require(
      BenchClockProbePacket(bytes: BenchClockProbePacket.request(sequence: 7, clientSendNs: 1_000).bytes))
    let reply = try #require(
      BenchClockProbePacket(bytes: request.reply(receivedNs: -5_000, sentNs: -4_000).bytes))

    #expect(reply.kind == .reply)
    #expect(reply.sequence == 7)
    #expect(
      reply.exchange(clientReceiveNs: 3_000)
        == BenchClockExchange(localSendNs: 1_000, remoteReceiveNs: -5_000, remoteSendNs: -4_000, localReceiveNs: 3_000))
  }

  private struct Datagram: CustomTestStringConvertible, Sendable {
    let name: String
    let bytes: [UInt8]

    var testDescription: String { name }

    static func probe(magic: String = "CVCP", version: UInt8 = 1, kind: UInt8 = 1) -> [UInt8] {
      Array(magic.utf8) + [version, kind] + [UInt8](repeating: 0, count: 34)
    }
  }

  private static let foreignDatagrams = [
    Datagram(name: "another protocol", bytes: Datagram.probe(magic: "XXXX")),
    Datagram(name: "another version", bytes: Datagram.probe(version: 2)),
    Datagram(name: "an unknown kind", bytes: Datagram.probe(kind: 9)),
    Datagram(name: "a truncated probe", bytes: Array(Datagram.probe().dropLast())),
  ]

  @Test(arguments: foreignDatagrams)
  private func datagramsThatAreNotProbesAreRejected(_ datagram: Datagram) {
    #expect(BenchClockProbePacket(bytes: datagram.bytes) == nil)
  }
}
