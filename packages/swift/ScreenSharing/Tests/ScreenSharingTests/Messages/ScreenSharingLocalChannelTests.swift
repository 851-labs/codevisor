import CodevisorTestSupport
import Foundation
import ScreenSharingTesting
import Testing

@testable import ScreenSharing

/// The in-memory channel pair keeps the native channel's contract: ordered
/// delivery through a hop (never reentrant), availability that both ends
/// observe, and refused sends once either end has closed.
@MainActor
struct ScreenSharingLocalChannelTests {
  @Test func deliversInOrderThroughTheHopAndNeverReentrantly() {
    let hop = ScreenSharingManualHop()
    let (viewer, host) = ScreenSharingLocalChannel<Int>.pair(hop: hop.schedule)
    var hostReceived: [Int] = []
    var viewerReceived: [Int] = []
    host.onMessage = { value in
      hostReceived.append(value)
      #expect(host.send(value * 10))  // a reply from inside delivery is queued, not delivered inline
    }
    viewer.onMessage = { viewerReceived.append($0) }
    #expect(viewer.isAvailable && host.isAvailable)
    #expect(viewer.send(1) && viewer.send(2))
    #expect(hostReceived.isEmpty)
    hop.drain()
    #expect(hostReceived == [1, 2])
    #expect(viewerReceived.isEmpty)
    hop.drain()
    #expect(viewerReceived == [10, 20])
    #expect(viewer.sentCount == 2 && host.sentCount == 2)
  }

  @Test func closingOneEndMakesBothUnavailableAndRefusesLaterSends() {
    let hop = ScreenSharingManualHop()
    let (viewer, host) = ScreenSharingLocalChannel<String>.pair(hop: hop.schedule)
    var viewerAvailability: [Bool] = []
    var hostAvailability: [Bool] = []
    var hostReceived: [String] = []
    viewer.onAvailabilityChanged = { viewerAvailability.append($0) }
    host.onAvailabilityChanged = { hostAvailability.append($0) }
    host.onMessage = { hostReceived.append($0) }
    #expect(viewer.send("in flight"))
    host.close()
    #expect(hostAvailability == [false])
    #expect(!host.isAvailable && !viewer.isAvailable)
    #expect(!viewer.send("after close") && !host.send("after close"))
    #expect(viewerAvailability.isEmpty)
    hop.drain()
    #expect(viewerAvailability == [false])
    #expect(hostReceived.isEmpty)  // a message in flight to a closed end is dropped, never delivered late
    host.close()
    hop.drain()
    #expect(hostAvailability == [false] && viewerAvailability == [false])
  }

  @Test func aBurstKeepsItsOrderThroughOneHopAndCountsOnlyAcceptedSends() {
    let hop = ScreenSharingManualHop()
    let (viewer, host) = ScreenSharingLocalChannel<Int>.pair(hop: hop.schedule)
    var received: [Int] = []
    host.onMessage = { received.append($0) }
    for value in 1...64 { #expect(viewer.send(value)) }
    #expect(viewer.sentCount == 64)
    hop.drain()
    #expect(received == Array(1...64))
    host.close()
    #expect(!viewer.send(65))
    #expect(viewer.sentCount == 64)
  }

  @Test func closingFromInsideDeliveryDropsTheRestOfTheBatch() {
    let hop = ScreenSharingManualHop()
    let (viewer, host) = ScreenSharingLocalChannel<Int>.pair(hop: hop.schedule)
    var received: [Int] = []
    host.onMessage = { value in
      received.append(value)
      if value == 2 { host.close() }
    }
    for value in 1...3 { #expect(viewer.send(value)) }
    hop.drain()
    // The third message was already queued; a channel that closed mid-batch never delivers it.
    #expect(received == [1, 2])
    hop.drain()
    #expect(received == [1, 2])
  }

  @Test func anAvailabilityCallbackCannotSendOnTheChannelItIsReportingClosed() {
    let hop = ScreenSharingManualHop()
    let (viewer, host) = ScreenSharingLocalChannel<String>.pair(hop: hop.schedule)
    var refusedInsideCallback: Bool?
    viewer.onAvailabilityChanged = { available in
      #expect(!available)
      refusedInsideCallback = !viewer.send("from the callback")
    }
    host.onMessage = { _ in Issue.record("a closed channel delivered a message") }
    viewer.close()
    #expect(refusedInsideCallback == true)
    hop.drainAll()
  }

  /// The default hop is a main-actor task, so delivery is asynchronous even without a test hop.
  @Test func theDefaultHopDeliversOnTheMainActorAfterTheSendReturns() async {
    let (viewer, host) = ScreenSharingLocalChannel<Int>.pair()
    let delivered = TestSignal()
    var received: [Int] = []
    host.onMessage = { value in
      received.append(value)
      delivered.signal()
    }
    #expect(viewer.send(7))
    #expect(received.isEmpty)
    await delivered.wait()
    #expect(received == [7])
  }
}
