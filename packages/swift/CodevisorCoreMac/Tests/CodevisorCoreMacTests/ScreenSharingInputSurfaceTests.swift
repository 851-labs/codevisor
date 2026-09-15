import AppKit
import CodevisorScreenSharing
import ScreenSharingHostInput
import Testing
@testable import CodevisorCoreMac

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
    #expect(fixture.control.state == .controlling)
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
    #expect(fixture.control.state == .controlling)
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
    #expect(fixture.control.state == .viewing && !fixture.input.active)
    #expect(fixture.keyboard.stops == 1)
    #expect(fixture.events.isEmpty)
    #expect(!fixture.keyboard.send(.keyDown, try fixture.systemKey(code: 49, flags: .maskCommand)))
  }

  @Test func interruptedCaptureReleasesHeldKeysAndControl() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    #expect(fixture.keyboard.send(.keyDown, try fixture.systemKey(code: 12, flags: .maskCommand)))
    fixture.keyboard.interrupted?()
    #expect(fixture.control.state == .viewing && !fixture.input.active)
    #expect(
      fixture.events.suffix(2) == [
        .key(code: 12, down: false, repeatKey: false, modifiers: 8),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(fixture.control.message?.contains("Keyboard capture stopped") == true)
    #expect(fixture.keyboard.stops == 1)
  }

  @Test func unavailableKeyboardCaptureReleasesTheGrantWithAnActionableMessage() throws {
    let fixture = try InputSurfaceFixture(keyboardStarts: false)
    defer { fixture.close() }
    #expect(fixture.control.state == .viewing && !fixture.input.active)
    #expect(fixture.control.message?.contains("Accessibility") == true)
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
    #expect(fixture.control.state == .controlling)
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
    #expect(fixture.control.state == .controlling)
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
    #expect(fixture.control.state == .controlling)

    fixture.window.key = false
    fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
    #expect(fixture.control.state == .controlling)
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
    #expect(fixture.control.state == .controlling)
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

  @Test func escapeFromLocalControlsStillReleasesTheLease() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    _ = fixture.input.route(try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 510)))
    #expect(fixture.input.route(try fixture.key(.keyDown, code: 53, flags: [.control, .option])) == nil)
    #expect(fixture.control.state == .viewing)
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
    fixture.control.release()
    #expect(fixture.control.state == .viewing)
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
  lazy var control = ScreenSharingViewerControl(send: { [unowned self] in
    messages.append($0); return true
  })

  init(keyboardStarts: Bool = true) throws {
    _ = NSApplication.shared
    window = InputTestWindow(
      contentRect: .init(x: 0, y: 0, width: 640, height: 540), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(view)
    keyboard.starts = keyboardStarts
    input = ScreenSharingInputSurface(
      view: view, notificationCenter: notifications, keyboardCapture: keyboard,
      applicationIsActive: { [application] in application.active })
    input.onInput = { [unowned self] in
      events.append($0); control.input($0)
    }
    input.onRelease = { [unowned self] in control.release(reason: input.failureMessage) }
    control.onActiveChanged = { [unowned self] active in
      if active {
        if !input.begin() { control.release(reason: input.failureMessage) }
      } else {
        input.end()
      }
    }
    control.setAvailable(true)
    control.request()
    guard case .request(let id) = try #require(messages.last) else { throw FixtureError.noRequest }
    control.receive(.grant(request: id, lease: UUID()))
    #expect(control.state == (keyboardStarts ? .controlling : .viewing))
  }

  func close() { control.release(); input.end(); window.close() }

  func systemKey(code: UInt16, down: Bool = true, flags: CGEventFlags = []) throws -> CGEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
    event.flags = flags
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

  private enum FixtureError: Error { case noRequest }
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
  func pointer(_ event: NSEvent, clamp: Bool) -> ScreenSharingPointer? { .init(x: 0.5, y: 0.5) }
  func controlCursorChanged() {}
}
