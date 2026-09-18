import AppKit
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingControlTests {
  @Test func leaseExpiryReleasesAllHeldInputAndRejectsDelayedPackets() throws {
    let fixture = HostControlFixture()
    let lease = try fixture.acquire()
    fixture.receive(lease, 1, .key(code: 55, down: true, repeatKey: false, modifiers: 8))
    fixture.receive(lease, 2, .key(code: 0, down: true, repeatKey: false, modifiers: 8))
    fixture.receive(lease, 3, .button(.init(x: 0.25, y: 0.75), button: 0, down: true, clicks: 1, modifiers: 8))
    fixture.time = 2.999
    fixture.host.checkDeadline()
    #expect(fixture.events.count == 3)
    fixture.time = 3
    fixture.host.checkDeadline()
    #expect(
      fixture.events.suffix(3) == [
        .key(code: 0, down: false, repeatKey: false, modifiers: 8),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
        .button(.init(x: 0.25, y: 0.75), button: 0, down: false, clicks: 1, modifiers: 0),
      ])
    #expect(fixture.host.heldKeys.isEmpty && fixture.host.heldButtons.isEmpty)
    fixture.host.revoke("Duplicate close")
    fixture.host.receive(.heartbeat(lease: lease))
    fixture.receive(lease, 4, .key(code: 1, down: true, repeatKey: false, modifiers: 0))
    #expect(fixture.events.count == 6)
    let fresh = try fixture.acquire()
    #expect(fresh != lease)
    fixture.receive(lease, 5, .key(code: 1, down: true, repeatKey: false, modifiers: 0))
    #expect(fixture.events.count == 6)
    fixture.host.revoke("Test complete")
  }

  @Test func heartbeatRequiresMatchingLeaseAndCannotReviveAnExpiredGrant() throws {
    let fixture = HostControlFixture()
    let lease = try fixture.acquire()
    fixture.time = 2
    fixture.host.receive(.heartbeat(lease: UUID()))
    fixture.host.receive(.heartbeat(lease: lease))
    fixture.time = 4.999
    fixture.host.checkDeadline()
    #expect(fixture.host.lease == lease)
    fixture.time = 5
    fixture.host.receive(.heartbeat(lease: lease))
    #expect(fixture.host.lease == nil)
  }

  @Test func deniedPermissionAndRevocationCannotInjectOrKeepKeysHeld() throws {
    let fixture = HostControlFixture()
    fixture.reason = "Accessibility required"
    fixture.host.receive(.request(id: UUID()))
    #expect(fixture.host.lease == nil && fixture.events.isEmpty)
    fixture.reason = nil
    let lease = try fixture.acquire()
    fixture.receive(lease, 1, .key(code: 0, down: true, repeatKey: false, modifiers: 0))
    fixture.reason = "Permission revoked"
    fixture.receive(lease, 2, .key(code: 1, down: true, repeatKey: false, modifiers: 0))
    #expect(
      fixture.events == [
        .key(code: 0, down: true, repeatKey: false, modifiers: 0),
        .key(code: 0, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(fixture.host.lease == nil)
  }

  @Test func duplicateAndOutOfOrderEventsDoNotReplayTransitions() throws {
    let fixture = HostControlFixture()
    let lease = try fixture.acquire()
    let down = ScreenSharingInputEvent.key(code: 0, down: true, repeatKey: false, modifiers: 0)
    fixture.receive(lease, 1, down)
    fixture.receive(lease, 1, down)
    fixture.receive(lease, 2, down)
    fixture.receive(lease, 3, .key(code: 0, down: true, repeatKey: true, modifiers: 0))
    fixture.receive(lease, 2, .key(code: 0, down: false, repeatKey: false, modifiers: 0))
    #expect(fixture.events.count == 2)
    fixture.host.receive(.release(lease: lease))
    #expect(fixture.events.count == 3)
    #expect(fixture.host.heldKeys.isEmpty)
  }

  @Test func invalidInputRevokesControlAndReleasesAButton() throws {
    let fixture = HostControlFixture()
    let lease = try fixture.acquire()
    fixture.receive(lease, 1, .button(.init(x: 0, y: 0), button: 1, down: true, clicks: 1, modifiers: 0))
    fixture.receive(lease, 2, .move(.init(x: -1, y: 0), modifiers: 0))
    #expect(fixture.host.lease == nil)
    #expect(fixture.events.count == 2)
    #expect(fixture.host.heldButtons.isEmpty)
  }

  @Test func quartzMappingUsesGlobalPointsAndProducesNativeDragAndReleaseEvents() throws {
    var events: [CGEvent] = []
    let injector = ScreenSharingInputInjector(displayBounds: CGRect(x: -1440, y: -900, width: 1440, height: 900)) {
      events.append($0)
    }
    let point = ScreenSharingPointer(x: 0.25, y: 0.75)
    injector.post(.button(point, button: 0, down: true, clicks: 2, modifiers: 8))
    injector.post(.move(point, modifiers: 8))
    injector.post(.button(point, button: 0, down: false, clicks: 2, modifiers: 0))
    injector.post(.move(point, modifiers: 0))
    #expect(events.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved])
    #expect(events.allSatisfy { $0.location == CGPoint(x: -1080, y: -225) })
    #expect(events[0].flags == .maskCommand)
    #expect(events[0].getIntegerValueField(.mouseEventClickState) == 2)
    #expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == ScreenSharingInputInjector.eventTag })
    injector.post(.key(code: 0, down: true, repeatKey: true, modifiers: 1))
    #expect(events.last?.getIntegerValueField(.keyboardEventAutorepeat) == 1)
    #expect(events.last?.flags == .maskShift)
    #expect(injector.location(.init(x: 1, y: 1)).x < 0)
    #expect(injector.location(.init(x: 1, y: 1)).y < 0)
  }
}

@MainActor
private final class HostControlFixture {
  var time = 0.0
  var reason: String?
  var events: [ScreenSharingInputEvent] = []
  var sent: [ScreenSharingControlMessage] = []
  lazy var host = ScreenSharingHostControl(
    now: { [unowned self] in time }, availability: { [unowned self] in reason },
    inject: { [unowned self] in events.append($0) },
    send: { [unowned self] in
      sent.append($0); return true
    })
  func acquire() throws -> UUID {
    host.receive(.request(id: UUID()))
    return try #require(host.lease)
  }
  func receive(_ lease: UUID, _ sequence: UInt64, _ event: ScreenSharingInputEvent) {
    host.receive(.input(lease: lease, sequence: sequence, event: event))
  }
}
