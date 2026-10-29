import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

private let poisonByte: UInt8 = 0xFF

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingDataChannelTests {
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

    init(holdPoison: DispatchSemaphore? = nil) async throws {
      harness = try await ScreenSharingPeerLoopbackTests.Harness()
      let decode: @Sendable (Data) throws -> Data = { data in
        guard data.first != poisonByte else {
          holdPoison?.wait()
          throw ScreenSharingError.invalid("Undecodable packet.")
        }
        return data
      }
      host = try await harness.sender.transport.perform { connection in
        try ScreenSharingDataChannel<Data>(
          connection: connection, id: 30, label: "codevisor.test.v1", encode: { $0 }, decode: decode)
      }
      viewer = try await harness.receiver.transport.perform { connection in
        try ScreenSharingDataChannel<Data>(
          connection: connection, id: 30, label: "codevisor.test.v1", encode: { $0 }, decode: decode)
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

    func open() async throws {
      try await harness.negotiate()
      await opened.cancellableWait(for: 2)
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
    let payloads = [Data([1]), Data([2, 3]), Data(repeating: 7, count: 1_000), Data([4])]
    for payload in payloads { #expect(pair.host.send(payload)) }
    await pair.delivered.cancellableWait(for: payloads.count)
    #expect(pair.received == payloads)
    #expect(pair.viewerAvailability == [true])

    pair.close()
    #expect(pair.viewerAvailability == [true, false])
    #expect(!pair.viewer.send(Data([9])) && !pair.host.send(Data([9])))
  }

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
    await pair.delivered.cancellableWait(for: payloads.count)
    #expect(pair.received == payloads)
  }

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
    await taken.recorded.cancellableWait(for: 2)
    await pair.delivered.cancellableWait(for: 3)
    #expect(taken.messages == [Data([0xA0, 1]), Data([0xA0, 2])])
    #expect(!taken.sawMainThread)
    #expect(pair.received == [Data([1]), Data([2]), Data([3])])
  }

  @Test func aPacketThatCannotBeDecodedClosesTheReceivingChannelAndDropsTheRest() async throws {
    let releaseDecode = DispatchSemaphore(value: 0)
    let pair = try await Pair(holdPoison: releaseDecode)
    defer {
      releaseDecode.signal()
      pair.close()
    }
    try await pair.open()
    #expect(pair.host.send(Data([1])))
    await pair.delivered.cancellableWait()

    #expect(pair.host.send(Data([poisonByte, 1])))
    #expect(pair.host.send(Data([2])))
    await withCheckedContinuation { continuation in
      let sent = DispatchGroup()
      pair.host.afterQueuedWork(in: sent)
      sent.notify(queue: .main) { continuation.resume() }
    }
    releaseDecode.signal()
    await pair.viewerClosed.cancellableWait()
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
    await pair.delivered.cancellableWait()
    #expect(pair.received == [admissible])

    #expect(pair.host.send(Data(repeating: 2, count: ScreenSharingControlMessage.maximumBytes + 1)))
    await pair.viewerClosed.cancellableWait()
    #expect(pair.received == [admissible])
    #expect(!pair.viewer.isAvailable)
  }

  @Test func aMessageLargerThanTheSendBudgetIsRefusedAndClosesTheSendingChannel() async throws {
    let pair = try await Pair()
    defer { pair.close() }
    try await pair.open()
    #expect(!pair.host.send(Data(repeating: 1, count: 16 * 1_024 + 1)))
    await pair.hostClosed.cancellableWait()
    #expect(!pair.host.isAvailable && pair.hostAvailability == [true, false])
    #expect(pair.received.isEmpty)
    #expect(!pair.host.send(Data([1])))
  }
}

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
