import Foundation
import Testing
@testable import CodevisorScreenSharing

/// The in-memory channel pair keeps the native channel's contract: ordered
/// delivery through a hop (never reentrant), availability that both ends
/// observe, and refused sends once either end has closed.
@MainActor
struct ScreenSharingLocalChannelTests {
  @Test func deliversInOrderThroughTheHopAndNeverReentrantly() {
    let hop = ManualHop()
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
    let hop = ManualHop()
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

  /// Queued main-actor work that a test releases explicitly.
  @MainActor
  private final class ManualHop {
    private var queued: [@Sendable @MainActor () -> Void] = []
    nonisolated init() {}
    nonisolated func schedule(_ work: @escaping @Sendable @MainActor () -> Void) {
      MainActor.assumeIsolated { queued.append(work) }
    }
    func drain() {
      let batch = queued
      queued = []
      for work in batch { work() }
    }
  }
}
