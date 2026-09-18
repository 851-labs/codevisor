import ScreenSharing
import CodevisorTestSupport
import CustomDump
import Foundation
import Observation
import Testing
@testable import CodevisorCoreMac

/// The endpoint's control-plane surface as the lease reducer sees it through
/// `ScreenSharingEndpointClient`: the event stream, numbered input forwarding
/// and its congestion cut-off, refused capture, and what closing releases.
@MainActor
struct ScreenSharingViewerEndpointTests {
  @Test func controlEventsOpenWithAvailabilityThenCarryMessagesAndInputLoss() async throws {
    let fixture = EndpointFixture()
    fixture.session.controlChannel.isAvailable = true
    let endpoint = fixture.make()
    let log = fixture.observe(endpoint)
    await awaitObserved { log.events.count >= 1 }
    expectNoDifference(log.events, [.availability(true)])
    let lease = UUID()
    fixture.session.controlChannel.deliver(.grant(request: UUID(), lease: lease))
    fixture.surface.inputFailureMessage = "Keyboard capture stopped."
    fixture.surface.onInputReleased?()
    await awaitObserved { log.events.count >= 3 }
    expectNoDifference(
      log.events,
      [
        .availability(true), .message(.grant(request: log.grantRequest, lease: lease)),
        .inputLost("Keyboard capture stopped."),
      ])
    endpoint.close()
    await awaitObserved { log.finished }
    #expect(ScreenSharingEndpointRegistry.shared.endpoint(endpoint.id) == nil)
  }

  @Test func inputIsNumberedUnderTheLeaseAndCongestionEndsForwardingOnce() async throws {
    let fixture = EndpointFixture()
    fixture.session.controlChannel.isAvailable = true
    let endpoint = fixture.make()
    let log = fixture.observe(endpoint)
    await awaitObserved { log.events.count >= 1 }  // subscribed: later events have a consumer
    let lease = UUID()
    #expect(endpoint.beginInput(lease: lease) == nil)
    #expect(fixture.surface.inputActive)
    let move = ScreenSharingInputEvent.move(.init(x: 0.5, y: 0.5), modifiers: 0)
    fixture.surface.onInput?(move)
    fixture.surface.onInput?(.key(code: 0, down: true, repeatKey: false, modifiers: 0))
    expectNoDifference(
      fixture.session.controlChannel.sent,
      [
        .input(lease: lease, sequence: 1, event: move),
        .input(lease: lease, sequence: 2, event: .key(code: 0, down: true, repeatKey: false, modifiers: 0)),
      ])
    fixture.session.controlChannel.isAvailable = false  // the channel refuses the next send
    fixture.surface.onInput?(move)
    #expect(!fixture.surface.inputActive)
    fixture.surface.onInput?(move)
    expectNoDifference(fixture.session.controlChannel.sent.count, 2)
    await awaitObserved { log.events.contains { if case .inputLost = $0 { true } else { false } } }
    expectNoDifference(
      log.events.filter { if case .inputLost = $0 { true } else { false } },
      [.inputLost("Control paused because the connection could not keep up. Request control again.")])
    endpoint.close()
  }

  @Test func refusedCaptureReportsTheSurfaceMessageAndCloseReleasesAHeldLease() async throws {
    let fixture = EndpointFixture()
    fixture.session.controlChannel.isAvailable = true
    let endpoint = fixture.make()
    fixture.surface.beginInputSucceeds = false
    fixture.surface.inputFailureMessage = "Focus this window and request control again."
    #expect(endpoint.beginInput(lease: UUID()) == "Focus this window and request control again.")
    fixture.surface.beginInputSucceeds = true
    let lease = UUID()
    #expect(endpoint.beginInput(lease: lease) == nil)
    endpoint.close()
    expectNoDifference(fixture.session.controlChannel.sent.last, .release(lease: lease))
    #expect(fixture.surface.stopped && fixture.session.closed && !fixture.surface.inputActive)
    endpoint.close()
    expectNoDifference(fixture.session.controlChannel.sent.count, 1)
  }

  @Test func theLiveClientResolvesEndpointsByIdUntilTheyClose() async throws {
    let fixture = EndpointFixture()
    fixture.session.controlChannel.isAvailable = true
    let endpoint = fixture.make()
    let client = ScreenSharingEndpointClient.liveValue
    #expect(await client.sendControl(endpoint.id, .request(id: UUID())))
    #expect(await client.beginInput(endpoint.id, UUID()) == nil)
    #expect(fixture.surface.inputActive)
    await client.endInput(endpoint.id)
    #expect(!fixture.surface.inputActive)
    endpoint.close()
    #expect(await client.sendControl(endpoint.id, .request(id: UUID())) == false)
    #expect(await client.beginInput(endpoint.id, UUID()) == nil)
    var closedStream = await client.controlEvents(endpoint.id).makeAsyncIterator()
    #expect(await closedStream.next() == nil)
  }

  @MainActor
  private final class EndpointFixture {
    let session = FakeMediaSession()
    let surface = FakeSurface()
    private var consumer: Task<Void, Never>?

    func make() -> ScreenSharingViewerEndpoint {
      session.surface = surface
      return ScreenSharingViewerEndpoint(session: session, surface: surface)
    }

    func observe(_ endpoint: ScreenSharingViewerEndpoint) -> ControlEventLog {
      let log = ControlEventLog()
      consumer = Task { @MainActor in
        for await event in endpoint.controlEvents() {
          if case .message(.grant(let request, _)) = event { log.grantRequest = request }
          log.events.append(event)
        }
        log.finished = true
      }
      return log
    }
  }

  @MainActor
  @Observable
  final class ControlEventLog {
    var events: [ScreenSharingControlEvent] = []
    var finished = false
    var grantRequest = UUID()
  }
}
