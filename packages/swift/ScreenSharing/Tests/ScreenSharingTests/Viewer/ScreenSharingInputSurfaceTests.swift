import AppKit
import Carbon.HIToolbox
import ScreenSharing
import Testing
@testable import ScreenSharing

@MainActor
struct ScreenSharingInputSurfaceTests {
  @Test(arguments: [UInt16(49), 12, 48, 13, 4, 46, 50])
  func systemAndAppCommandShortcutsAreConsumedAndForwarded(code: UInt16) throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    #expect(fixture.keyboard.send(.keyDown, try fixture.systemKey(code: code, flags: .maskCommand)))
    #expect(fixture.keyboard.send(.keyUp, try fixture.systemKey(code: code, down: false, flags: .maskCommand)))
    #expect(fixture.keyboard.send(.flagsChanged, try fixture.systemKey(code: 55, down: false)))
    #expect(
      fixture.events == [
        .key(code: 55, down: true, repeatKey: false, modifiers: 8),
        .key(code: code, down: true, repeatKey: false, modifiers: 8),
        .key(code: code, down: false, repeatKey: false, modifiers: 8),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(fixture.controlling)
  }

  /// 851-2318: synthesized typing (key code 0 carrying the text) goes out as
  /// the text, once per press, its release swallowed; a real A key stays a key.
  @Test func synthesizedTypingIsSentAsTextAndPhysicalKeysStayKeys() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    for character in ["H", "ö", "!", "日"] {
      #expect(fixture.keyboard.send(.keyDown, try fixture.typed(character)))
      #expect(fixture.keyboard.send(.keyUp, try fixture.typed(character, down: false)))
    }
    #expect(fixture.keyboard.send(.keyDown, try fixture.typed("a")))
    #expect(fixture.keyboard.send(.keyUp, try fixture.typed("a", down: false)))
    #expect(fixture.keyboard.send(.keyDown, try fixture.typed("A", flags: .maskShift)))
    #expect(fixture.keyboard.send(.keyUp, try fixture.typed("A", down: false, flags: .maskShift)))
    #expect(
      fixture.events == [
        .text("H"), .text("ö"), .text("!"), .text("日"),
        .key(code: 0, down: true, repeatKey: false, modifiers: 0),
        .key(code: 0, down: false, repeatKey: false, modifiers: 0),
        .key(code: 56, down: true, repeatKey: false, modifiers: 1),
        .key(code: 0, down: true, repeatKey: false, modifiers: 1),
        .key(code: 0, down: false, repeatKey: false, modifiers: 1),
      ])
  }

  /// Control and Command change a key's characters by design (⌃A is U+0001): still a physical key.
  @Test func controlAndCommandKeepKeyCodeZeroPhysical() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    #expect(fixture.keyboard.send(.keyDown, try fixture.typed("\u{01}", flags: .maskControl)))
    #expect(fixture.events.last == .key(code: 0, down: true, repeatKey: false, modifiers: 2))
  }

  @Test func systemShortcutsStayLocalOutsideTheFocusedVideo() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    let shortcut = try fixture.systemKey(code: 49, flags: .maskCommand)
    let activateVideo = {
      fixture.application.active = true
      fixture.window.key = true
      fixture.view.isHidden = false
      #expect(fixture.window.makeFirstResponder(fixture.view))
      fixture.input.resume()
    }
    fixture.application.active = false
    #expect(!fixture.keyboard.send(.keyDown, shortcut))
    activateVideo()
    fixture.window.key = false
    #expect(!fixture.keyboard.send(.keyDown, shortcut))
    activateVideo()
    fixture.view.isHidden = true
    #expect(!fixture.keyboard.send(.keyDown, shortcut))
    activateVideo()
    let editor = NSTextView(frame: .init(x: 0, y: 490, width: 100, height: 30))
    fixture.window.contentView?.addSubview(editor)
    #expect(fixture.window.makeFirstResponder(editor))
    #expect(!fixture.keyboard.send(.keyDown, shortcut))
    activateVideo()
    fixture.notifications.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
    #expect(!fixture.keyboard.send(.keyDown, shortcut))
    #expect(fixture.events.isEmpty)
    #expect(fixture.controlling)
    activateVideo()
    #expect(fixture.keyboard.send(.keyDown, shortcut))
  }

  @Test func injectedHostKeysAreNotCapturedAndEscapeReleasesSystemCapture() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    let injected = try fixture.systemKey(code: 12, flags: .maskCommand)
    injected.setIntegerValueField(.eventSourceUserData, value: ScreenSharingInputInjector.eventTag)
    #expect(!fixture.keyboard.send(.keyDown, injected))
    #expect(fixture.events.isEmpty)
    #expect(fixture.keyboard.send(.keyDown, try fixture.systemKey(code: 53, flags: [.maskControl, .maskAlternate])))
    #expect(!fixture.controlling && !fixture.input.active)
    #expect(fixture.keyboard.stops == 1)
    #expect(fixture.events.isEmpty)
    #expect(!fixture.keyboard.send(.keyDown, try fixture.systemKey(code: 49, flags: .maskCommand)))
  }

  @Test func interruptedCaptureReleasesHeldKeysAndControl() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    #expect(fixture.keyboard.send(.keyDown, try fixture.systemKey(code: 12, flags: .maskCommand)))
    fixture.keyboard.interrupted?()
    #expect(!fixture.controlling && !fixture.input.active)
    #expect(
      fixture.events.suffix(2) == [
        .key(code: 12, down: false, repeatKey: false, modifiers: 8),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(fixture.releaseReason?.contains("Keyboard capture stopped") == true)
    #expect(fixture.keyboard.stops == 1)
  }

  @Test func unavailableKeyboardCaptureReleasesTheGrantWithAnActionableMessage() throws {
    let fixture = try InputSurfaceFixture(keyboardStarts: false)
    defer { fixture.close() }
    #expect(!fixture.controlling && !fixture.input.active)
    #expect(fixture.releaseReason?.contains("Accessibility") == true)
    #expect(fixture.messages.contains { if case .release = $0 { true } else { false } })
    #expect(fixture.events.isEmpty)
  }

  @Test func toolbarClickReleasesHeldInputWithoutReleasingControl() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    #expect(fixture.input.route(try fixture.key(.keyDown, code: 0, flags: .command)) == nil)
    fixture.input.mouse(try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 100), flags: .command))

    let toolbarClick = try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 510))
    #expect(fixture.input.route(toolbarClick) === toolbarClick)
    #expect(fixture.controlling)
    #expect(fixture.input.active)
    #expect(fixture.window.firstResponder === fixture.view)  // A menu button need not take first responder.
    #expect(fixture.events.contains(.key(code: 0, down: false, repeatKey: false, modifiers: 8)))
    #expect(fixture.events.contains(.key(code: 55, down: false, repeatKey: false, modifiers: 0)))
    #expect(fixture.events.last == .button(.init(x: 0.5, y: 0.5), button: 0, down: false, clicks: 1, modifiers: 0))
    let count = fixture.events.count
    let localKey = try fixture.key(.keyDown, code: 125)
    #expect(fixture.input.route(localKey) === localKey)
    fixture.input.mouse(try fixture.mouse(.mouseMoved, at: .init(x: 100, y: 100)))
    fixture.input.suspend()
    #expect(fixture.events.count == count)

    let videoClick = try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 100))
    #expect(fixture.input.route(videoClick) === videoClick)
    #expect(fixture.input.route(try fixture.key(.keyDown, code: 1)) == nil)
    #expect(fixture.events.last == .key(code: 1, down: true, repeatKey: false, modifiers: 0))
    #expect(fixture.controlling)
    #expect(!fixture.messages.contains { if case .release = $0 { true } else { false } })
  }

  @Test func localEditorAndPopoverKeepTheLeaseAndReceiveTheirOwnKeys() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    let editor = NSTextView(frame: .init(x: 0, y: 490, width: 100, height: 30))
    fixture.window.contentView?.addSubview(editor)
    #expect(fixture.window.makeFirstResponder(editor))
    let localKey = try fixture.key(.keyDown, code: 0)
    #expect(fixture.input.route(localKey) === localKey)
    #expect(fixture.events.isEmpty)
    #expect(fixture.controlling)

    fixture.window.key = false
    fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
    #expect(fixture.controlling)
    #expect(fixture.input.route(localKey) === localKey)
    fixture.window.key = true
    let videoClick = try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 100))
    _ = fixture.input.route(videoClick)
    #expect(fixture.window.firstResponder === fixture.view)
    #expect(fixture.input.route(localKey) == nil)
    #expect(fixture.events.count == 1)
  }

  @Test func appDeactivationPausesInputWithoutChangingTheSelectedMode() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    _ = fixture.input.route(try fixture.key(.keyDown, code: 0))
    fixture.window.key = false
    fixture.notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(fixture.controlling)
    #expect(fixture.events.last == .key(code: 0, down: false, repeatKey: false, modifiers: 0))
    let count = fixture.events.count
    let key = try fixture.key(.keyDown, code: 1)
    #expect(fixture.input.route(key) === key)
    fixture.window.key = true
    #expect(fixture.input.route(key) === key)  // Returning to the app alone does not route local editor input.
    #expect(fixture.events.count == count)
    _ = fixture.input.route(try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 100)))
    #expect(fixture.input.route(key) == nil)
    #expect(fixture.events.last == .key(code: 1, down: true, repeatKey: false, modifiers: 0))
  }

  /// ⌘Tab away and back with the video still first responder: input was
  /// suspended (not live, so the pointer must be the arrow, not the host's
  /// cursor) and resumes when the app is active and the window key again.
  /// Before, nothing resumed it: the pointer stayed invisible over the video
  /// and moves went nowhere until a click.
  @Test func returningToTheAppResumesInputWhenTheVideoStillHasFocus() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    #expect(fixture.input.isLive)
    let changes = fixture.view.cursorChanges
    fixture.application.active = false
    fixture.window.key = false
    fixture.notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(!fixture.input.isLive && fixture.input.active, "suspended, lease kept")
    #expect(fixture.view.cursorChanges == changes + 1, "the pointer goes back to the arrow")
    fixture.application.active = true
    fixture.window.key = true
    fixture.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(fixture.input.isLive)
    #expect(fixture.view.cursorChanges == changes + 2, "the host's cursor again")
    // Keys reach the host again without a click.
    #expect(fixture.keyboard.send(.keyDown, try fixture.systemKey(code: 12)))
    #expect(fixture.events.last == .key(code: 12, down: true, repeatKey: false, modifiers: 0))
  }

  /// Returning while something else has focus (a local editor, a sheet) stays suspended.
  @Test func returningWithAnotherResponderStaysSuspended() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    fixture.notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    let editor = NSTextView(frame: .init(x: 0, y: 490, width: 100, height: 30))
    fixture.window.contentView?.addSubview(editor)
    #expect(fixture.window.makeFirstResponder(editor))
    fixture.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    fixture.notifications.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
    #expect(!fixture.input.isLive)
    // A menu closing doesn't resume it either while the editor has focus.
    fixture.notifications.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
    #expect(!fixture.input.isLive)
  }

  @Test func escapeFromLocalControlsStillReleasesTheLease() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    _ = fixture.input.route(try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 510)))
    #expect(fixture.input.route(try fixture.key(.keyDown, code: 53, flags: [.control, .option])) == nil)
    #expect(!fixture.controlling)
    #expect(!fixture.input.active)
    #expect(fixture.messages.contains { if case .release = $0 { true } else { false } })
    let localKey = try fixture.key(.keyDown, code: 0)
    #expect(fixture.input.route(localKey) === localKey)
    #expect(fixture.events.isEmpty)
  }

  @Test func explicitViewOnlyEndsInputEvenWhileToolbarHasFocus() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    _ = fixture.input.route(try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 510)))
    fixture.release(reason: nil)
    #expect(!fixture.controlling)
    #expect(!fixture.input.active)
    let click = try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 100))
    _ = fixture.input.route(click)
    fixture.input.mouse(click)
    #expect(fixture.events.isEmpty)
  }
}

@MainActor
private final class InputSurfaceFixture {
  let window: InputTestWindow
  let view = InputTestView(frame: .init(x: 0, y: 0, width: 640, height: 480))
  let input: ScreenSharingInputSurface
  let notifications = NotificationCenter()
  let keyboard = InputTestKeyboardCapture()
  let application = InputTestApplication()
  var messages: [ScreenSharingControlMessage] = []
  var events: [ScreenSharingInputEvent] = []
  /// The lease's data plane, wired exactly as the endpoint wires it.
  lazy var forwarder = ScreenSharingInputForwarder(send: { [unowned self] in
    messages.append($0); return true
  })
  /// The lease the host granted; the fixture plays the lease reducer's part around it.
  private(set) var lease: UUID? = UUID()
  /// The reason the lease was given back, as the lease reducer would receive it.
  private(set) var releaseReason: String?
  var controlling: Bool { forwarder.isActive }

  /// What the lease reducer does on `.inputLost`: stop forwarding and capture, release the lease on the wire.
  func release(reason: String?) {
    releaseReason = reason
    if let lease { messages.append(.release(lease: lease)) }
    lease = nil
    forwarder.end()
    input.end()
  }

  init(keyboardStarts: Bool = true) throws {
    _ = NSApplication.shared
    window = InputTestWindow(
      contentRect: .init(x: 0, y: 0, width: 640, height: 540), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(view)
    keyboard.starts = keyboardStarts
    input = ScreenSharingInputSurface(
      view: view, notificationCenter: notifications, keyboardCapture: keyboard,
      applicationIsActive: { [application] in application.active },
      // A fixed layout (key 0 is A), not the developer's: the synthesized-text check compares against it.
      layout: { code, carbon in code == 0 ? (carbon & UInt32(Carbon.shiftKey >> 8) != 0 ? "A" : "a") : "x" })
    input.onInput = { [unowned self] in
      events.append($0); forwarder.forward($0)
    }
    input.onRelease = { [unowned self] in release(reason: input.failureMessage) }
    forwarder.onLost = { [unowned self] in release(reason: $0) }
    if input.begin(), let lease { forwarder.begin(lease: lease) } else { release(reason: input.failureMessage) }
    #expect(controlling == keyboardStarts)
  }

  func close() { release(reason: nil); window.close() }

  func systemKey(code: UInt16, down: Bool = true, flags: CGEventFlags = []) throws -> CGEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
    event.flags = flags
    return event
  }

  /// A key event carrying `text`, the way Computer Use `typeText` posts it (key code 0 by default).
  func typed(_ text: String, code: UInt16 = 0, down: Bool = true, flags: CGEventFlags = []) throws -> CGEvent {
    let event = try systemKey(code: code, down: down, flags: flags)
    let units = Array(text.utf16)
    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    return event
  }

  func key(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code))
  }

  func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 1,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
  }

}

@MainActor
private final class InputTestApplication {
  var active = true
}

@MainActor
private final class InputTestKeyboardCapture: ScreenSharingKeyboardCapture {
  var starts = true
  var stops = 0
  var handle: ((CGEventType, CGEvent) -> Bool)?
  var interrupted: (() -> Void)?
  func start(handle: @escaping (CGEventType, CGEvent) -> Bool, interrupted: @escaping () -> Void) -> Bool {
    guard starts else { return false }
    self.handle = handle; self.interrupted = interrupted
    return true
  }
  func send(_ type: CGEventType, _ event: CGEvent) -> Bool {
    event.type = type
    return handle?(type, event) ?? false
  }
  func stop() { stops += 1; handle = nil; interrupted = nil }
}

@MainActor
private final class InputTestWindow: NSWindow {
  var key = true
  override var isKeyWindow: Bool { key }
}

@MainActor
private final class InputTestView: NSView, ScreenSharingInputTarget {
  override var acceptsFirstResponder: Bool { true }
  /// How often the surface asked for the pointer to be re-evaluated (host cursor vs. arrow).
  private(set) var cursorChanges = 0
  func pointer(_ event: NSEvent, clamp: Bool) -> ScreenSharingPointer? { .init(x: 0.5, y: 0.5) }
  func controlCursorChanged() { cursorChanges += 1 }
}
