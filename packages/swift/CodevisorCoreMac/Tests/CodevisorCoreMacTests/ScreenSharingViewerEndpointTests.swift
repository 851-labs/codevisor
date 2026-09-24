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

  /// 851-2340: with Dynamic Resolution on, the desktop follows the pane at the
  /// backing scale and the server is asked for the matching UI scale once;
  /// moving to a 1× display follows at 1×.
  @Test func dynamicResolutionFollowsThePaneAtTheBackingScale() async {
    let fixture = EndpointFixture()
    let endpoint = fixture.make()
    defer { endpoint.close() }
    let scales = ScaleLog()
    endpoint.setDesktopScale = { scales.append($0) }
    endpoint.desktopCanScale = true
    endpoint.setDynamicResolution(true)
    fixture.surface.onSizeChanged?(CGSize(width: 640.4, height: 400), 2)
    fixture.surface.onSizeChanged?(CGSize(width: 700, height: 400), 2)
    fixture.surface.onSizeChanged?(CGSize(width: 640, height: 400), 1)  // moved to a 1× display
    #expect(fixture.session.desktopSizeRequests == [[1281, 800], [1400, 800], [640, 400]])
    await awaitObserved { scales.values.count == 2 }
    #expect(scales.values == [2, 1], "the scale is sent when it changes, not with every size")
  }

  /// A slow link keeps a Retina pane at 1× pixels (hysteresis in ScreenSharingDynamicResolution).
  @Test func aSlowLinkKeepsARetinaPaneAtOneX() {
    let fixture = EndpointFixture()
    fixture.session.linkBitsPerSecond = 3_000_000
    let endpoint = fixture.make()
    defer { endpoint.close() }
    endpoint.desktopCanScale = true
    endpoint.setDynamicResolution(true)
    fixture.surface.onSizeChanged?(CGSize(width: 640, height: 400), 2)
    #expect(fixture.session.desktopSizeRequests == [[640, 400]])
  }

  /// A desktop that can't draw at 2× (an older server, no scaler) stays at 1× pixels on a
  /// Retina pane: a 2× framebuffer would only make its UI half size.
  @Test func aDesktopThatCannotScaleStaysAtOneXPixels() {
    let fixture = EndpointFixture()
    let endpoint = fixture.make()
    defer { endpoint.close() }
    endpoint.setDynamicResolution(true)
    fixture.surface.onSizeChanged?(CGSize(width: 640, height: 400), 2)
    #expect(fixture.session.desktopSizeRequests == [[640, 400]])
  }

  /// Off: the pane never resizes the desktop; turning it off after it did
  /// restores the provisioned size (or the size at connect) and 1×.
  @Test func turningDynamicResolutionOffRestoresTheDesktop() async {
    let fixture = EndpointFixture()
    let endpoint = fixture.make()
    defer { endpoint.close() }
    let scales = ScaleLog()
    endpoint.setDesktopScale = { scales.append($0) }
    endpoint.desktopCanScale = true
    fixture.surface.onSizeChanged?(CGSize(width: 640, height: 400), 2)
    #expect(fixture.session.desktopSizeRequests.isEmpty, "off by default here: nothing sent")
    endpoint.setDynamicResolution(true)
    #expect(fixture.session.desktopSizeRequests == [[1280, 800]])
    endpoint.defaultDesktopSize = (1440, 900)
    endpoint.setDynamicResolution(false)
    #expect(fixture.session.desktopSizeRequests == [[1280, 800], [1440, 900]])
    await awaitObserved { scales.values == [2, 1] }
    fixture.surface.onSizeChanged?(CGSize(width: 800, height: 500), 2)
    #expect(fixture.session.desktopSizeRequests.count == 2, "off: pane changes send nothing")
    // Without a provisioned size, the size seen at connect is restored.
    let other = EndpointFixture()
    let second = other.make()
    defer { second.close() }
    second.setDynamicResolution(true)
    other.surface.onSizeChanged?(CGSize(width: 640, height: 400), 1)
    second.setDynamicResolution(false)
    #expect(other.session.desktopSizeRequests == [[640, 400], [1024, 768]])
  }

  /// A backend that can't resize (a Mac) offers no toggle and sends nothing.
  @Test func aDesktopThatCannotResizeIsLeftAlone() {
    let fixture = EndpointFixture(resizes: false)
    let endpoint = fixture.make()
    defer { endpoint.close() }
    #expect(!endpoint.supportsDynamicResolution)
    endpoint.setDynamicResolution(true)
    fixture.surface.onSizeChanged?(CGSize(width: 640, height: 400), 2)
    #expect(fixture.session.desktopSizeRequests.isEmpty)
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

    init(resizes: Bool = true) { session.resizesDesktop = resizes }

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

/// The scales the endpoint asked the server for, in order (observable: tests await it).
@MainActor
@Observable
private final class ScaleLog {
  private(set) var values: [Int] = []
  func append(_ value: Int) { values.append(value) }
}
