import AppKit
import CodevisorTestSupport
import Testing

@testable import ScreenSharing

/// What the viewer sends for local pointer activity: button tracking, the
/// coalesced drag, the scroll scale, and the release owed to the host when the
/// video stops being the focused surface. Each test owns its window, and the
/// coalescing window is a `TestClock`, so no expectation depends on a 16 ms
/// wall-clock timer firing (or not) mid-assertion.
@MainActor
struct ScreenSharingInputSurfacePointerTests {
  @Test func aDragIsCoalescedIntoOneMoveBracketedByItsButton() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 160, y: 405)))
    #expect(fixture.events == [.button(.init(x: 0.25, y: 0.25), button: 0, down: true, clicks: 1, modifiers: 0)])
    fixture.input.mouse(try fixture.mouse(.leftMouseDragged, at: .init(x: 320, y: 270)))
    fixture.input.mouse(try fixture.mouse(.leftMouseDragged, at: .init(x: 480, y: 135)))
    #expect(fixture.events.count == 1, "intermediate motion waits for the coalescing window")
    fixture.input.mouse(try fixture.mouse(.leftMouseUp, at: .init(x: 480, y: 135)))
    #expect(
      fixture.events == [
        .button(.init(x: 0.25, y: 0.25), button: 0, down: true, clicks: 1, modifiers: 0),
        .move(.init(x: 0.75, y: 0.75), modifiers: 0),
        .button(.init(x: 0.75, y: 0.75), button: 0, down: false, clicks: 1, modifiers: 0),
      ])
    // Only the press itself is unclamped: once a button is held, a drag that
    // leaves the video keeps pushing the remote pointer along the edge.
    #expect(fixture.view.clamps == [false, true, true, true])
  }

  @Test func motionIsFlushedOncePerCoalescingWindow() async throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.input.mouse(try fixture.mouse(.mouseMoved, at: .init(x: 320, y: 270)))
    fixture.input.mouse(try fixture.mouse(.mouseMoved, at: .init(x: 160, y: 405)))
    await fixture.clock.waitForSleep(.milliseconds(16))
    #expect(fixture.events.isEmpty, "nothing is sent before the window closes")
    fixture.clock.advance(by: .milliseconds(16))
    await fixture.received.wait(for: 1)
    #expect(fixture.events == [.move(.init(x: 0.25, y: 0.25), modifiers: 0)], "two moves collapse into the newest")

    await fixture.clock.waitForSleep(.milliseconds(16), count: 2)
    fixture.clock.advance(by: .milliseconds(16))
    await fixture.clock.waitForSleep(.milliseconds(16), count: 3)
    #expect(fixture.events.count == 1, "an idle window sends nothing")
  }

  @Test func preciseAndLineScrollsUseTheirOwnScaleAndStopAtTheProtocolBound() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    let corner = ScreenSharingPointer(x: 0, y: 0)
    fixture.input.mouse(try fixture.scroll(x: 2, y: 3, precise: true))
    #expect(fixture.events == [.scroll(corner, x: 2, y: 3, modifiers: 0)])
    fixture.input.mouse(try fixture.scroll(x: 0, y: 1, precise: false))
    #expect(fixture.events.last == .scroll(corner, x: 0, y: 12, modifiers: 0), "one wheel line is twelve pixels")
    fixture.input.mouse(try fixture.scroll(x: 0, y: 0, precise: true))
    #expect(fixture.events.count == 2, "a scroll that resolves to nothing is not sent")
    // The accumulator saturates at the value the control message allows, so a
    // flick can never produce an event the host would reject as invalid.
    fixture.input.mouse(try fixture.scroll(x: 0, y: 400, precise: false))
    let saturated = try #require(fixture.events.last)
    #expect(saturated == .scroll(corner, x: 0, y: 4096, modifiers: 0))
    #expect(saturated.isValid)
  }

  @Test func momentumScrollingIsForwardedLikeAnyOtherScroll() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.input.mouse(try fixture.scroll(x: 0, y: 4, precise: true, momentumPhase: 0))
    fixture.input.mouse(try fixture.scroll(x: 0, y: 2, precise: true, momentumPhase: 2))
    fixture.input.mouse(try fixture.scroll(x: 0, y: 1, precise: true, momentumPhase: 3))
    let corner = ScreenSharingPointer(x: 0, y: 0)
    #expect(
      fixture.events == [
        .scroll(corner, x: 0, y: 4, modifiers: 0),
        .scroll(corner, x: 0, y: 2, modifiers: 0),
        .scroll(corner, x: 0, y: 1, modifiers: 0),
      ])
  }

  @Test func modifierChangesBecomeSyntheticKeysBeforeTheEventThatCarriesThem() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270), flags: [.shift, .command]))
    #expect(
      fixture.events == [
        .key(code: 56, down: true, repeatKey: false, modifiers: 1),
        .key(code: 55, down: true, repeatKey: false, modifiers: 9),
        .button(.init(x: 0.5, y: 0.5), button: 0, down: true, clicks: 1, modifiers: 9),
      ])
    fixture.input.mouse(try fixture.mouse(.leftMouseUp, at: .init(x: 320, y: 270)))
    #expect(
      fixture.events.suffix(3) == [
        .key(code: 56, down: false, repeatKey: false, modifiers: 8),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
        .button(.init(x: 0.5, y: 0.5), button: 0, down: false, clicks: 1, modifiers: 0),
      ])
  }

  @Test func capsLockTravelsInTheFlagsWithoutASyntheticKey() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270), flags: .capsLock))
    #expect(fixture.events == [.button(.init(x: 0.5, y: 0.5), button: 0, down: true, clicks: 1, modifiers: 16)])
  }

  @Test func secondaryButtonsKeepTheirNumberAndClickCount() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    let corner = ScreenSharingPointer(x: 0, y: 0)
    fixture.input.mouse(try fixture.button(.rightMouseDown, button: .right, clicks: 1))
    fixture.input.mouse(try fixture.button(.rightMouseUp, button: .right, clicks: 1))
    fixture.input.mouse(try fixture.button(.otherMouseDown, button: .center, clicks: 2))
    fixture.input.mouse(try fixture.button(.otherMouseUp, button: .center, clicks: 7))
    #expect(
      fixture.events == [
        .button(corner, button: 1, down: true, clicks: 1, modifiers: 0),
        .button(corner, button: 1, down: false, clicks: 1, modifiers: 0),
        .button(corner, button: 2, down: true, clicks: 2, modifiers: 0),
        .button(corner, button: 2, down: false, clicks: 3, modifiers: 0),
      ])
    let valid = fixture.events.allSatisfy { $0.isValid }
    #expect(valid, "the click count stays inside the protocol's range")
  }

  @Test func theInjectorsOwnClicksAreNotSentBackToTheHost() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    let injected = try fixture.button(.leftMouseDown, button: .left, clicks: 1)
    injected.cgEvent?.setIntegerValueField(.eventSourceUserData, value: ScreenSharingInputInjector.eventTag)
    fixture.input.mouse(injected)
    #expect(fixture.events.isEmpty)
  }

  @Test func losingFocusReleasesTheHeldButtonAtTheLastKnownPointAndDropsPendingMotion() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 160, y: 405)))
    fixture.input.mouse(try fixture.mouse(.leftMouseDragged, at: .init(x: 320, y: 270)))
    fixture.notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(
      fixture.events == [
        .button(.init(x: 0.25, y: 0.25), button: 0, down: true, clicks: 1, modifiers: 0),
        .button(.init(x: 0.5, y: 0.5), button: 0, down: false, clicks: 1, modifiers: 0),
      ], "the host must not be left holding a drag, and the unsent motion is discarded")
    #expect(fixture.input.active, "the lease survives the focus change")

    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270)))
    #expect(fixture.events.count == 2, "a suspended surface forwards nothing")
    fixture.input.resume()
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270)))
    #expect(fixture.events.count == 3)
  }

  @Test func aPointOutsideTheRemoteDisplayIsNotForwarded() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.view.mapsPointer = false
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270)))
    fixture.input.mouse(try fixture.mouse(.leftMouseUp, at: .init(x: 320, y: 270)))
    #expect(fixture.events.isEmpty)
    // The refused press was never tracked as held, so the next press is still
    // the unclamped one that starts a drag.
    fixture.view.mapsPointer = true
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270)))
    #expect(fixture.view.clamps.last == false)
  }

  @Test func localControlsThatTakeFirstResponderStopThePointerStream() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    let editor = NSTextView(frame: .init(x: 0, y: 0, width: 10, height: 10))
    fixture.window.contentView?.addSubview(editor)
    #expect(fixture.window.makeFirstResponder(editor))
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270)))
    #expect(fixture.events.isEmpty)
  }

  @Test func endingInputClearsTheHeldStateWithoutSendingAnything() throws {
    let fixture = try PointerFixture()
    defer { fixture.close() }
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 320, y: 270), flags: .shift))
    let count = fixture.events.count
    fixture.input.end()
    #expect(!fixture.input.active)
    #expect(fixture.events.count == count, "ending input is the caller's decision, not a release to forward")
    fixture.input.mouse(try fixture.mouse(.leftMouseUp, at: .init(x: 320, y: 270)))
    #expect(fixture.events.count == count)
  }
}

@MainActor
private final class PointerFixture {
  let window: PointerTestWindow
  let view: PointerTestView
  let input: ScreenSharingInputSurface
  let clock = TestClock()
  let notifications = NotificationCenter()
  let keyboard = StubKeyboardCapture()
  let received = TestSignal()
  var events: [ScreenSharingInputEvent] = []

  init() throws {
    _ = NSApplication.shared
    window = PointerTestWindow(
      contentRect: .init(x: 0, y: 0, width: 640, height: 540), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    view = PointerTestView(frame: .init(x: 0, y: 0, width: 640, height: 540))
    window.contentView?.addSubview(view)
    window.contentView?.layoutSubtreeIfNeeded()
    input = ScreenSharingInputSurface(
      view: view, notificationCenter: notifications, keyboardCapture: keyboard, applicationIsActive: { true },
      clock: clock)
    input.onInput = { [unowned self] event in
      events.append(event)
      received.signal()
    }
    #expect(input.begin())
    view.clamps = []
  }

  func close() {
    input.end()
    window.close()
  }

  func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
  }

  /// Scroll wheel and middle-button events cannot be built through
  /// `NSEvent.mouseEvent` (AppKit traps), so they come from Quartz. Such an
  /// event reports the window's top-left corner as its location, which the
  /// fixture's target maps to the remote origin.
  func scroll(x: Int32, y: Int32, precise: Bool, momentumPhase: Int64 = 0) throws -> NSEvent {
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    return try windowed(event)
  }

  func button(_ type: CGEventType, button: CGMouseButton, clicks: Int64) throws -> NSEvent {
    let event = try #require(
      CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button))
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    return try windowed(event)
  }

  /// Field 51 is the window number `NSEvent(cgEvent:)` resolves its window
  /// from; the requirement below fails loudly if a synthesized event ever
  /// stops belonging to this fixture's window, rather than silently routing
  /// nothing.
  private func windowed(_ event: CGEvent) throws -> NSEvent {
    // A nil-source event starts with the modifier keys physically held right now: a developer
    // holding ⌘ during the suite made these scrolls carry Command. No modifiers, explicitly.
    event.flags = []
    event.setIntegerValueField(try #require(CGEventField(rawValue: 51)), value: Int64(window.windowNumber))
    let native = try #require(NSEvent(cgEvent: event))
    #expect(native.window === window)
    return native
  }
}

@MainActor
private final class PointerTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

/// Maps window points onto the remote display over its own bounds with a
/// top-left origin — the same normalization the product surface performs after
/// letterboxing, which `ScreenSharingVideoSurfaceLetterboxTests` covers with
/// the real geometry.
@MainActor
private final class PointerTestView: NSView, ScreenSharingInputTarget {
  var mapsPointer = true
  var clamps: [Bool] = []
  override var acceptsFirstResponder: Bool { true }

  func pointer(_ event: NSEvent, clamp: Bool) -> ScreenSharingPointer? {
    clamps.append(clamp)
    guard mapsPointer else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    let x = point.x / bounds.width
    let y = (bounds.height - point.y) / bounds.height
    let mapped = ScreenSharingPointer(
      x: clamp ? min(1, max(0, x)) : x, y: clamp ? min(1, max(0, y)) : y)
    return mapped.isValid ? mapped : nil
  }

  func controlCursorChanged() {}
}

@MainActor
private final class StubKeyboardCapture: ScreenSharingKeyboardCapture {
  func start(handle: @escaping (CGEventType, CGEvent) -> Bool, interrupted: @escaping () -> Void) -> Bool { true }
  func stop() {}
}
