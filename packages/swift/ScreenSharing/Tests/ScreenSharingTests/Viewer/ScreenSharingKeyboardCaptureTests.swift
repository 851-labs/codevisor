import AppKit
import Testing

@testable import ScreenSharing

/// The real system capture, driven through a recording installer: the tap it
/// registers is never handed to Quartz, so the suite exercises the callback's
/// consume/pass-through decision and the capture's teardown without taking the
/// developer's keyboard away from them.
@MainActor
struct ScreenSharingKeyboardCaptureTests {
  @Test func theInstalledTapListensForKeyEventsOnlyAndConsumesWhatTheSurfaceHandles() throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let recorder = CaptureRecorder()
    #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    #expect(installer.installs == 1)
    let expected = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    #expect(installer.mask == expected)

    recorder.handled = true
    let consumed = try keyEvent(code: 12)
    #expect(installer.deliver(.keyDown, consumed) == nil, "a handled key never reaches the rest of the system")
    recorder.handled = false
    let passed = try keyEvent(code: 12, down: false)
    #expect(installer.deliver(.keyUp, passed) === passed)
    #expect(recorder.events.map(\.0) == [CGEventType.keyDown, .keyUp])
    #expect(recorder.events.map { $0.1 } == [consumed, passed])
    #expect(recorder.interruptions == 0)
  }

  @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
  func aDisabledTapReportsTheInterruptionAndLeavesTheEventAlone(type: CGEventType) throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let recorder = CaptureRecorder()
    recorder.handled = true
    #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    let event = try keyEvent(code: 12)
    #expect(installer.deliver(type, event) === event)
    #expect(recorder.interruptions == 1)
    #expect(recorder.events.isEmpty, "a disabled-tap notice is not a key press")
  }

  @Test func anEventWithoutTheCaptureContextIsPassedThrough() throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let recorder = CaptureRecorder()
    recorder.handled = true
    #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    let event = try keyEvent(code: 12)
    #expect(installer.deliver(.keyDown, event, withContext: false) === event)
    #expect(recorder.events.isEmpty)
  }

  @Test func aRefusedTapFailsTheStartAndKeepsNoHandlers() {
    let installer = RecordingTapInstaller()
    installer.available = false
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let recorder = CaptureRecorder()
    #expect(!capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    #expect(installer.installs == 1)
    #expect(!installer.isInstalled)
    capture.stop()
    #expect(installer.teardowns == 0, "nothing was installed, so nothing is torn down")
  }

  @Test func restartingTearsDownThePreviousTapBeforeInstallingTheNextOne() throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let first = CaptureRecorder()
    let second = CaptureRecorder()
    first.handled = true
    second.handled = true
    #expect(capture.start(handle: first.handle, interrupted: first.interrupt))
    #expect(capture.start(handle: second.handle, interrupted: second.interrupt))
    #expect(installer.installs == 2)
    #expect(installer.teardowns == 1)
    #expect(installer.deliver(.keyDown, try keyEvent(code: 12)) == nil)
    #expect(first.events.isEmpty, "the replaced tap's handler is gone")
    #expect(second.events.count == 1)

    capture.stop()
    #expect(installer.teardowns == 2)
    #expect(!installer.isInstalled)
    capture.stop()
    #expect(installer.teardowns == 2, "stopping twice tears down once")
  }

  @Test func droppingTheCaptureTearsDownItsTap() throws {
    let installer = RecordingTapInstaller()
    do {
      let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
      let recorder = CaptureRecorder()
      #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
      #expect(installer.isInstalled)
    }
    #expect(installer.teardowns == 1, "the isolated deinit releases the tap")
    #expect(!installer.isInstalled)
  }

  private func keyEvent(code: UInt16, down: Bool = true) throws -> CGEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
    event.flags = []  // not whatever modifiers happen to be held on this Mac
    return event
  }
}

/// Stands in for Quartz: keeps the callback and context the capture registers
/// and replays them on demand, counting installs and teardowns.
@MainActor
private final class RecordingTapInstaller: ScreenSharingKeyboardTapInstaller {
  var available = true
  private(set) var installs = 0
  private(set) var teardowns = 0
  private(set) var mask: CGEventMask = 0
  private var callback: CGEventTapCallBack?
  private var context: UnsafeMutableRawPointer?
  var isInstalled: Bool { callback != nil }

  func install(
    eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, context: UnsafeMutableRawPointer
  ) -> (() -> Void)? {
    installs += 1
    guard available else { return nil }
    mask = eventsOfInterest
    self.callback = callback
    self.context = context
    return { [weak self] in
      guard let self else { return }
      teardowns += 1
      self.callback = nil
      self.context = nil
    }
  }

  /// Delivers one event the way the session tap would. Returns the event the
  /// tap lets through, or nil when the capture consumed it.
  func deliver(_ type: CGEventType, _ event: CGEvent, withContext: Bool = true) -> CGEvent? {
    guard let callback, let proxy = CGEventTapProxy(bitPattern: 1) else {
      Issue.record("No tap is installed")
      return nil
    }
    return callback(proxy, type, event, withContext ? context : nil)?.takeUnretainedValue()
  }
}

@MainActor
private final class CaptureRecorder {
  var handled = false
  private(set) var events: [(CGEventType, CGEvent)] = []
  private(set) var interruptions = 0
  lazy var handle: (CGEventType, CGEvent) -> Bool = { [unowned self] type, event in
    events.append((type, event))
    return handled
  }
  lazy var interrupt: () -> Void = { [unowned self] in interruptions += 1 }
}
