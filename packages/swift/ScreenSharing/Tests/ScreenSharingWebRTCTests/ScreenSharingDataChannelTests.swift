import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

/// The first byte of a packet the test decoder refuses, standing in for any
/// malformed frame the remote could put on the wire.
private let poisonByte: UInt8 = 0xFF

/// The negotiated data channel over its real SCTP carrier. A fourth channel is
/// added to the loopback pair so the carrier's framing and its failure handling
/// can be exercised with payloads the three protocol channels cannot express.
@MainActor
struct ScreenSharingDataChannelTests {
  /// Both ends of one extra negotiated channel, wired before negotiation and
  /// observed entirely through its own callbacks.
  @MainActor
  final class Pair {
    let harness: ScreenSharingPeerLoopbackTests.Harness
    let host: ScreenSharingDataChannel<Data>
    let viewer: ScreenSharingDataChannel<Data>
    let opened = TestSignal()
    let delivered = TestSignal()
    let viewerClosed = TestSignal()
    let hostClosed = TestSignal()
    private(set) var received: [Data] = []
    private(set) var viewerAvailability: [Bool] = []
    private(set) var hostAvailability: [Bool] = []

    init() throws {
      harness = try ScreenSharingPeerLoopbackTests.Harness()
      let decode: @Sendable (Data) throws -> Data = { data in
        guard data.first != poisonByte else {
          throw ScreenSharingError.invalid("Undecodable packet.")
        }
        return data
      }
      host = try ScreenSharingDataChannel<Data>(
        connection: harness.sender.connection, id: 6, label: "codevisor.test.v1", encode: { $0 }, decode: decode)
      viewer = try ScreenSharingDataChannel<Data>(
        connection: harness.receiver.connection, id: 6, label: "codevisor.test.v1", encode: { $0 }, decode: decode)
      viewer.onMessage = { [self] data in
        received.append(data)
        delivered.signal()
      }
      viewer.onAvailabilityChanged = { [self] available in
        viewerAvailability.append(available)
        if available { opened.signal() } else { viewerClosed.signal() }
      }
      host.onAvailabilityChanged = { [self] available in
        hostAvailability.append(available)
        if available { opened.signal() } else { hostClosed.signal() }
      }
    }

    /// Returns once both ends have published their opening, so later
    /// availability sequences start from a known point.
    func open() async throws {
      try await harness.negotiate()
      await opened.wait(for: 2)
      #expect(host.isAvailable && viewer.isAvailable)
      #expect(hostAvailability == [true] && viewerAvailability == [true])
    }

    func close() {
      host.close()
      viewer.close()
      harness.close()
    }
  }

  @Test func everySendArrivesAsOneWholeMessageInTheOrderItWasWritten() async throws {
    let pair = try Pair()
    defer { pair.close() }
    try await pair.open()
    // Distinct lengths, including one that spans more than a single SCTP chunk:
    // a fused or split delivery would change the sequence, not just its timing.
    let payloads = [Data([1]), Data([2, 3]), Data(repeating: 7, count: 1_000), Data([4])]
    for payload in payloads { #expect(pair.host.send(payload)) }
    await pair.delivered.wait(for: payloads.count)
    #expect(pair.received == payloads)
    #expect(pair.viewerAvailability == [true])

    pair.close()
    // Teardown is idempotent and publishes exactly one availability change.
    #expect(pair.viewerAvailability == [true, false])
    #expect(!pair.viewer.send(Data([9])) && !pair.host.send(Data([9])))
  }

  @Test func aPacketThatCannotBeDecodedClosesTheReceivingChannelAndDropsTheRest() async throws {
    let pair = try Pair()
    defer { pair.close() }
    try await pair.open()
    #expect(pair.host.send(Data([1])))
    await pair.delivered.wait()

    // The whole batch containing the bad packet is abandoned, so the trailing
    // good packet is never delivered either.
    #expect(pair.host.send(Data([poisonByte, 1])))
    #expect(pair.host.send(Data([2])))
    await pair.viewerClosed.wait()
    #expect(pair.received == [Data([1])])
    #expect(!pair.viewer.isAvailable && pair.viewerAvailability == [true, false])
    #expect(!pair.viewer.send(Data([3])))
  }

  @Test func aPacketOverThePerPacketAdmissionLimitClosesTheReceivingChannel() async throws {
    let pair = try Pair()
    defer { pair.close() }
    try await pair.open()
    let admissible = Data(repeating: 1, count: ScreenSharingControlMessage.maximumBytes)
    #expect(pair.host.send(admissible))
    await pair.delivered.wait()
    #expect(pair.received == [admissible])

    #expect(pair.host.send(Data(repeating: 2, count: ScreenSharingControlMessage.maximumBytes + 1)))
    await pair.viewerClosed.wait()
    #expect(pair.received == [admissible])
    #expect(!pair.viewer.isAvailable)
  }

  @Test func aMessageLargerThanTheSendBudgetIsRefusedAndClosesTheSendingChannel() async throws {
    let pair = try Pair()
    defer { pair.close() }
    try await pair.open()
    #expect(!pair.host.send(Data(repeating: 1, count: 16 * 1_024 + 1)))
    await pair.hostClosed.wait()
    // The send budget is a transport failure, not a dropped message: the
    // channel gives up rather than carrying an unbounded backlog.
    #expect(!pair.host.isAvailable && pair.hostAvailability == [true, false])
    #expect(pair.received.isEmpty)
    #expect(!pair.host.send(Data([1])))
  }
}
