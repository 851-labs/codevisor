import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// ContinuousUpdates (-313) and Fence (-312), 851-2312: once the server
/// confirms continuous updates the client stops requesting and the server
/// pushes changes; fence requests are answered, and the client's own fences
/// measure the round trip.
struct RFBContinuousUpdatesTests {
  typealias Harness = RFBClientLoopbackTests.Harness

  static func modernServer() -> RFBLoopbackServer.Configuration {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.continuousUpdates = true
    configuration.fences = true
    return configuration
  }

  // MARK: L1 — wire format

  @Test func messagesHaveTheirRegisteredLayouts() {
    #expect(
      RFBClientMessage.enableContinuousUpdates(enable: true, RFBRectangle(x: 1, y: 2, width: 640, height: 480)).encoded
        == [150, 1, 0, 1, 0, 2, 2, 128, 1, 224])
    #expect(
      RFBClientMessage.fence(flags: RFBFence.request | RFBFence.blockBefore, payload: [7, 8]).encoded
        == [248, 0, 0, 0, 0x80, 0, 0, 1, 2, 7, 8])
  }

  @Test func messagesRoundTripThroughTheServerSideReader() async throws {
    for message in [
      RFBClientMessage.enableContinuousUpdates(enable: false, RFBRectangle(x: 0, y: 0, width: 3, height: 4)),
      .fence(flags: RFBFence.syncNext, payload: [1, 2, 3]),
    ] {
      let stream = RFBInputStream(transport: ScriptedTransport(message.encoded))
      #expect(try await RFBClientMessage.read(from: stream) == message)
    }
  }

  @Test func oversizedFencePayloadsAreRejected() async throws {
    let stream = RFBInputStream(
      transport: ScriptedTransport([0, 0, 0, 0, 0, 0, 0, 65] + Array(repeating: 0, count: 65)))
    await #expect(throws: RFBError.self) { _ = try await RFBFence.read(from: stream) }
  }

  // MARK: L2 — against the reference server

  @Test func updatesArePushedWithoutRequestsOnceTheServerConfirms() async throws {
    let harness = try await Harness(configuration: Self.modernServer())
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    #expect(await awaitPolled { harness.server.isContinuous })
    #expect(harness.server.wantsUpdate, "No request is pending, yet a change would reach the client.")
    for index in 0..<3 {
      try harness.server.paint(RFBRectangle(x: index, y: 0, width: 1, height: 1), blue: 9, green: 9, red: 9)
      harness.server.enqueue([.raw(RFBRectangle(x: index, y: 0, width: 1, height: 1))])
      let update = try #require(await harness.nextUpdate())
      #expect(update.update.latency == nil, "A pushed update answers no request.")
    }
    let requests = harness.server.received.filter {
      if case .framebufferUpdateRequest = $0 { return true } else { return false }
    }
    #expect(
      requests == [.framebufferUpdateRequest(incremental: false, RFBRectangle(x: 0, y: 0, width: 64, height: 48))])
    #expect(
      harness.server.received.contains(
        .enableContinuousUpdates(enable: true, RFBRectangle(x: 0, y: 0, width: 64, height: 48))))
  }

  @Test func theServersFenceIsAnsweredWithOnlyTheFlagsTheClientHonours() async throws {
    let harness = try await Harness(configuration: Self.modernServer())
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    // The server asked with request + blockBefore; the reply clears request and echoes the payload.
    #expect(
      await awaitPolled {
        harness.server.fencesReceived.contains {
          $0.flags == RFBFence.blockBefore && $0.payload == RFBLoopbackServer.fenceProbe
        }
      })
  }

  @Test func theClientsOwnFencesMeasureTheRoundTrip() async throws {
    let harness = try await Harness(configuration: Self.modernServer())
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    var events: [RFBServerEvent] = []
    while let event = await harness.nextEvent() {
      events.append(event)
      if case .roundTrip = event { break }
    }
    #expect(events.first == .continuousUpdates(true))
    #expect(events.contains { if case .roundTrip(let rtt) = $0 { rtt >= .zero } else { false } })
    #expect(harness.server.fencesReceived.contains { $0.flags & RFBFence.request != 0 })
  }

  @Test func whenTheServerEndsThemTheClientRequestsAgain() async throws {
    let harness = try await Harness(configuration: Self.modernServer())
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    #expect(await awaitPolled { harness.server.isContinuous })
    #expect(harness.server.isRequestPending == false)
    harness.server.endContinuousUpdates()
    #expect(await awaitPolled { harness.server.isRequestPending }, "An incremental request resumes the loop.")
  }

  @Test func aResizeReenablesTheNewArea() async throws {
    let harness = try await Harness(configuration: Self.modernServer())
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    #expect(await awaitPolled { harness.server.isContinuous })
    harness.server.enqueue([.desktopSize(width: 32, height: 16)])
    #expect(try #require(await harness.nextUpdate()).update.resized)
    #expect(
      await awaitPolled {
        harness.server.received.contains(
          .enableContinuousUpdates(enable: true, RFBRectangle(x: 0, y: 0, width: 32, height: 16)))
      })
  }

  @Test func aServerWithoutThemKeepsTheRequestLoop() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let first = try #require(await harness.nextUpdate())
    #expect(first.update.latency != nil)
    #expect(await awaitPolled { harness.server.isRequestPending })
    #expect(!harness.server.isContinuous)
  }
}
