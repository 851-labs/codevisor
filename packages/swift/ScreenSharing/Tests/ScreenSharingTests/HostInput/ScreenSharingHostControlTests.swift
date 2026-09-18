import CodevisorTestSupport
import Foundation
import Testing

@testable import ScreenSharing

/// The host half of a control lease: who holds it, when it lapses, and what the
/// host owes the local machine when it takes the lease back. Every deadline is
/// virtual, so "just before" and "just after" the three-second window are exact
/// points rather than sleeps.
@MainActor
struct ScreenSharingHostControlTests {
  @Test func aRequestGrantsALeaseAndTheSecondViewerIsToldWhyItCannotHaveOne() throws {
    let host = HostFixture()
    let first = host.request()
    let lease = try #require(host.control.lease)
    #expect(host.messages == [.grant(request: first, lease: lease)])
    #expect(host.changes == [true])
    let second = UUID()
    host.control.receive(.request(id: second))
    #expect(host.messages.last == .denied(request: second, reason: "Control is already active."))
    #expect(host.control.lease != nil, "a refused request leaves the current lease alone")
  }

  @Test func anUnavailableHostDeniesTheRequestWithoutOpeningALease() {
    let host = HostFixture()
    host.availability = "Screen recording permission is required."
    let request = UUID()
    host.control.receive(.request(id: request))
    #expect(host.messages == [.denied(request: request, reason: "Screen recording permission is required.")])
    #expect(host.control.lease == nil)
    #expect(host.changes.isEmpty)
  }

  @Test func aGrantThatCannotBeSentIsRevokedImmediately() {
    let host = HostFixture()
    host.accepts = false
    let request = UUID()
    host.control.receive(.request(id: request))
    #expect(host.control.lease == nil)
    #expect(host.changes == [true, false])
    guard case .revoked(_, let reason) = host.messages.last else {
      Issue.record("Expected the lease to be revoked, got \(String(describing: host.messages.last))")
      return
    }
    #expect(reason == "The control channel closed.")
  }

  @Test func theLeaseSurvivesUpToItsDeadlineAndLapsesOnIt() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    host.advance(.milliseconds(2999))
    host.control.checkDeadline()
    #expect(host.control.lease == lease)
    host.advance(.milliseconds(1))
    host.control.checkDeadline()
    #expect(host.control.lease == nil)
    #expect(host.messages.last == .revoked(lease: lease, reason: "Control timed out. Request control again."))
    #expect(host.changes == [true, false])
  }

  @Test func aHeartbeatMovesTheDeadlineForwardByAWholeWindow() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    host.advance(.milliseconds(2500))
    host.control.receive(.heartbeat(lease: lease))
    host.advance(.milliseconds(2500))
    host.control.checkDeadline()
    #expect(host.control.lease == lease, "five seconds of held control, renewed halfway")
    host.advance(.milliseconds(500))
    host.control.checkDeadline()
    #expect(host.control.lease == nil)
  }

  @Test func aHeartbeatForAStaleLeaseNeitherRenewsNorDisturbsTheCurrentOne() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    host.advance(.milliseconds(2000))
    host.control.receive(.heartbeat(lease: UUID()))
    #expect(host.control.lease == lease)
    host.advance(.milliseconds(1000))
    host.control.checkDeadline()
    #expect(host.control.lease == nil, "the stranger's heartbeat did not extend the window")
  }

  @Test func losingHostAvailabilityDuringAHeartbeatEndsTheLease() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    host.availability = "The shared window closed."
    host.control.receive(.heartbeat(lease: lease))
    #expect(host.control.lease == nil)
    #expect(host.messages.last == .revoked(lease: lease, reason: "The shared window closed."))
  }

  @Test func inputIsAppliedInSequenceOrderAndRepeatsAreIgnored() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    let point = ScreenSharingPointer(x: 0.25, y: 0.5)
    host.control.receive(.input(lease: lease, sequence: 2, event: .move(point, modifiers: 0)))
    host.control.receive(.input(lease: lease, sequence: 2, event: .move(.init(x: 0.9, y: 0.9), modifiers: 0)))
    host.control.receive(.input(lease: lease, sequence: 1, event: .move(.init(x: 0.1, y: 0.1), modifiers: 0)))
    host.control.receive(.input(lease: UUID(), sequence: 3, event: .move(.init(x: 0.8, y: 0.8), modifiers: 0)))
    host.control.receive(.input(lease: lease, sequence: 3, event: .move(point, modifiers: 0)))
    #expect(host.injected == [.move(point, modifiers: 0), .move(point, modifiers: 0)])
    #expect(host.control.lease == lease, "a replay is dropped, not treated as an attack")
  }

  @Test func onlyPressesThatChangeTheHeldStateReachTheMachine() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    let point = ScreenSharingPointer(x: 0.5, y: 0.5)
    host.input(lease, .key(code: 12, down: false, repeatKey: false, modifiers: 0))
    host.input(lease, .key(code: 12, down: true, repeatKey: true, modifiers: 0))
    host.input(lease, .key(code: 12, down: true, repeatKey: false, modifiers: 0))
    host.input(lease, .key(code: 12, down: true, repeatKey: false, modifiers: 0))
    host.input(lease, .key(code: 12, down: true, repeatKey: true, modifiers: 0))
    host.input(lease, .button(point, button: 0, down: true, clicks: 1, modifiers: 0))
    host.input(lease, .button(point, button: 0, down: true, clicks: 1, modifiers: 0))
    host.input(lease, .text("hello"))
    #expect(
      host.injected == [
        .key(code: 12, down: true, repeatKey: false, modifiers: 0),
        .key(code: 12, down: true, repeatKey: true, modifiers: 0),
        .button(point, button: 0, down: true, clicks: 1, modifiers: 0),
      ])
    #expect(host.control.heldKeys == [12])
    #expect(host.control.heldButtons == [0])
  }

  @Test func pastedTextIsHeldBackWhileAKeyOrButtonIsDown() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    host.input(lease, .key(code: 55, down: true, repeatKey: false, modifiers: 8))
    host.input(lease, .text("v"))
    #expect(host.injected.count == 1, "pasting under a held ⌘ would type a shortcut instead")
    host.input(lease, .key(code: 55, down: false, repeatKey: false, modifiers: 0))
    host.input(lease, .text("v"))
    #expect(host.injected.last == .text("v"))
  }

  @Test func anInvalidEventEndsTheLeaseOnTheSpot() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    host.input(lease, .move(.init(x: 2, y: 0.5), modifiers: 0))
    #expect(host.injected.isEmpty)
    #expect(host.control.lease == nil)
    #expect(host.messages.last == .revoked(lease: lease, reason: "Invalid input received."))
  }

  @Test func revokingReleasesOrdinaryKeysBeforeModifiersAndThenTheHeldButtons() throws {
    let host = HostFixture()
    let lease = try #require(host.grant())
    host.input(lease, .button(.init(x: 0.25, y: 0.25), button: 0, down: true, clicks: 1, modifiers: 0))
    host.input(lease, .key(code: 56, down: true, repeatKey: false, modifiers: 1))
    host.input(lease, .key(code: 12, down: true, repeatKey: false, modifiers: 1))
    let last = ScreenSharingPointer(x: 0.75, y: 0.5)
    host.input(lease, .move(last, modifiers: 1))
    host.injected = []

    host.advance(.seconds(3))
    host.control.checkDeadline()
    #expect(
      host.injected == [
        .key(code: 12, down: false, repeatKey: false, modifiers: 1),
        .key(code: 56, down: false, repeatKey: false, modifiers: 0),
        .button(last, button: 0, down: false, clicks: 1, modifiers: 0),
      ], "shift must outlive the key it modified, and the button releases where the pointer last was")
    #expect(host.control.heldKeys.isEmpty && host.control.heldButtons.isEmpty)
    host.control.revoke("Again.")
    #expect(host.injected.count == 3, "revoking a lease that is already gone injects nothing")
  }

  @Test func theNextViewerGetsAFreshLeaseAndTheOldOneCannotSpeakAgain() throws {
    let host = HostFixture()
    let first = try #require(host.grant())
    host.input(first, .move(.init(x: 0.5, y: 0.5), modifiers: 0))
    host.control.receive(.release(lease: UUID()))
    #expect(host.control.lease == first, "only the holder can hand the lease back")
    host.control.receive(.release(lease: first))
    #expect(host.messages.last == .revoked(lease: first, reason: "Control released."))

    host.advance(.seconds(10))
    let second = try #require(host.grant())
    #expect(second != first)
    host.injected = []
    host.input(first, .move(.init(x: 0.1, y: 0.1), modifiers: 0))
    let point = ScreenSharingPointer(x: 0.9, y: 0.9)
    host.control.receive(.input(lease: second, sequence: 1, event: .move(point, modifiers: 0)))
    #expect(host.injected == [.move(point, modifiers: 0)], "numbering restarts for the new holder")
    #expect(host.changes == [true, false, true])
  }
}

@MainActor
private final class HostFixture {
  let clock = TestClock()
  var availability: String?
  var accepts = true
  var injected: [ScreenSharingInputEvent] = []
  private(set) var messages: [ScreenSharingControlMessage] = []
  private(set) var changes: [Bool] = []
  private let origin: ContinuousClock.Instant
  private(set) var control: ScreenSharingHostControl!

  init() {
    origin = clock.now
    control = ScreenSharingHostControl(
      now: { [clock, origin] in
        let elapsed = origin.duration(to: clock.now).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
      },
      availability: { [unowned self] in availability },
      inject: { [unowned self] in injected.append($0) },
      send: { [unowned self] in
        messages.append($0)
        return accepts
      })
    control.onChanged = { [unowned self] in changes.append($0) }
  }

  func advance(_ duration: Duration) { clock.advance(by: duration) }

  @discardableResult func request() -> UUID {
    let id = UUID()
    control.receive(.request(id: id))
    return id
  }

  func grant() -> UUID? {
    request()
    return control.lease
  }

  /// Numbering is the forwarder's job; here every event simply gets the next one.
  func input(_ lease: UUID, _ event: ScreenSharingInputEvent) {
    sequence += 1
    control.receive(.input(lease: lease, sequence: sequence, event: event))
  }
  private var sequence: UInt64 = 0
}
