import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

/// The first byte of a packet the test decoder refuses, standing in for any
/// malformed frame the remote could put on the wire.
private let poisonByte: UInt8 = 0xFF

/// The negotiated data channel over its real SCTP carrier. An extra channel is
/// added to the loopback pair so the carrier's framing and its failure handling
/// can be exercised with payloads the protocol channels cannot express.
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

    init() async throws {
      harness = try await ScreenSharingPeerLoopbackTests.Harness()
      let decode: @Sendable (Data) throws -> Data = { data in
        guard data.first != poisonByte else {
          throw ScreenSharingError.invalid("Undecodable packet.")
        }
        return data
      }
      // Created on each peer's transport queue, as the peer creates its own channels.
      host = try await harness.sender.transport.perform { connection in
        try ScreenSharingDataChannel<Data>(
          connection: connection, id: 16, label: "codevisor.test.v1", encode: { $0 }, decode: decode)
      }
      viewer = try await harness.receiver.transport.perform { connection in
        try ScreenSharingDataChannel<Data>(
          connection: connection, id: 16, label: "codevisor.test.v1", encode: { $0 }, decode: decode)
      }
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
    let pair = try await Pair()
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

  /// The host's audio sends from the capture's queue: `send` is safe from any thread, and the
  /// channel's queue keeps the order sends were made in.
  @Test func sendsFromAnotherThreadArriveInTheOrderTheyWereMade() async throws {
    let pair = try await Pair()
    defer { pair.close() }
    try await pair.open()
    let host = pair.host
    let payloads = (0..<20).map { Data([UInt8($0)]) }
    let accepted = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: payloads.map { host.send($0) })
      }
    }
    #expect(accepted == Array(repeating: true, count: payloads.count))
    await pair.delivered.wait(for: payloads.count)
    #expect(pair.received == payloads)
  }

  /// The viewer's audio is taken on the channel's queue and never waits for the main actor;
  /// everything else on the channel still reaches `onMessage` on main, in order.
  @Test func aConsumerTakesItsMessagesOffMainAndTheRestReachMainInOrder() async throws {
    let pair = try await Pair()
    defer { pair.close() }
    let taken = OffMainLog()
    pair.viewer.deliverOffMain { data in
      guard data.first == 0xA0 else { return false }
      taken.record(data)
      return true
    }
    try await pair.open()
    let payloads = [Data([1]), Data([0xA0, 1]), Data([2]), Data([0xA0, 2]), Data([3])]
    for payload in payloads { #expect(pair.host.send(payload)) }
    await taken.recorded.wait(for: 2)
    await pair.delivered.wait(for: 3)
    #expect(taken.messages == [Data([0xA0, 1]), Data([0xA0, 2])])
    #expect(!taken.sawMainThread)
    #expect(pair.received == [Data([1]), Data([2]), Data([3])])
  }

  @Test func aPacketThatCannotBeDecodedClosesTheReceivingChannelAndDropsTheRest() async throws {
    let pair = try await Pair()
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
    let pair = try await Pair()
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
    let pair = try await Pair()
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

/// What a consumer took on the channel's queue, and whether any of it ran on the main thread.
private final class OffMainLog: @unchecked Sendable {
  private let lock = NSLock()
  private var taken: [Data] = []
  private var onMain = false
  let recorded = TestSignal()

  func record(_ data: Data) {
    lock.withLock {
      taken.append(data)
      onMain = onMain || Thread.isMainThread
    }
    recorded.signal()
  }

  var messages: [Data] { lock.withLock { taken } }
  var sawMainThread: Bool { lock.withLock { onMain } }
}
