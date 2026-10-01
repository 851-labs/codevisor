import AppKit
import CodevisorTestSupport
import Testing

@testable import ScreenSharing

/// The real system capture, driven through a recording installer: the tap it
/// registers is never handed to Quartz, so the suite exercises the callback's
/// consume/pass-through decision and the capture's teardown without taking the
/// developer's keyboard away from them. The callback is invoked off the main
/// thread, as the tap's own thread invokes it.
@MainActor
struct ScreenSharingKeyboardCaptureTests {
  @Test func theTapDecidesOffMainFromTheClaimAndDeliversClaimedKeysToMainInOrder() async throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let recorder = CaptureRecorder()
    #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    #expect(installer.installs == 1)
    let expected = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    #expect(installer.mask == expected)
    let tap = try #require(installer.tap)

    #expect(await tap.deliver(.keyDown, code: 12) == .passed, "nothing is claimed before the surface says so")
    capture.setClaimsKeys(true)
    #expect(await tap.deliver(.keyDown, code: 12) == .consumed, "a claimed key never reaches the rest of the system")
    #expect(await tap.deliver(.keyUp, code: 12) == .consumed)
    #expect(await tap.deliver(.keyDown, code: 13, injected: true) == .passed, "the host's own injected keys pass")
    capture.setClaimsKeys(false)
    #expect(await tap.deliver(.keyDown, code: 14) == .passed)

    await recorder.delivered.wait(for: 2)
    await drainMainQueue()
    #expect(recorder.events.map(\.type) == [.keyDown, .keyUp])
    #expect(recorder.events.map(\.code) == [12, 12])
    #expect(recorder.interruptions == 0)
  }

  @Test func aTimedOutTapIsReenabledWhileAUserInputDisableInterrupts() async throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let recorder = CaptureRecorder()
    #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    capture.setClaimsKeys(true)
    let tap = try #require(installer.tap)

    #expect(await tap.deliver(.tapDisabledByTimeout, code: 12) == .passed)
    #expect(tap.reenables.value == 1, "a late answer turns the tap back on, on the tap's thread")
    #expect(await tap.deliver(.tapDisabledByUserInput, code: 12) == .passed)
    await recorder.interrupted.wait()
    // Main runs queued work in order: a timeout interruption would have arrived first.
    #expect(recorder.interruptions == 1)
    #expect(tap.reenables.value == 1)
    #expect(recorder.events.isEmpty, "a disabled-tap notice is not a key press")
  }

  @Test func aKeyQueuedForMainWhenTheCaptureStopsIsDropped() async throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    let recorder = CaptureRecorder()
    #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    capture.setClaimsKeys(true)
    let tap = try #require(installer.tap)
    // The tap's thread consumes the key and queues it for main; main stops before running it.
    let consumed = tap.deliverBlocking(.keyDown, code: 12)
    #expect(consumed == .consumed)
    capture.stop()
    await drainMainQueue()
    #expect(recorder.events.isEmpty)
  }

  @Test func anEventWithoutTheCaptureContextIsPassedThrough() async throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let recorder = CaptureRecorder()
    #expect(capture.start(handle: recorder.handle, interrupted: recorder.interrupt))
    capture.setClaimsKeys(true)
    let tap = try #require(installer.tap)
    #expect(await tap.deliver(.keyDown, code: 12, withContext: false) == .passed)
    await drainMainQueue()
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

  @Test func restartingTearsDownThePreviousTapBeforeInstallingTheNextOne() async throws {
    let installer = RecordingTapInstaller()
    let capture = ScreenSharingSystemKeyboardCapture(installer: installer)
    defer { capture.stop() }
    let first = CaptureRecorder()
    let second = CaptureRecorder()
    #expect(capture.start(handle: first.handle, interrupted: first.interrupt))
    let firstTap = try #require(installer.tap)
    capture.setClaimsKeys(true)
    #expect(capture.start(handle: second.handle, interrupted: second.interrupt))
    #expect(installer.installs == 2)
    #expect(installer.teardowns == 1)
    #expect(await firstTap.deliver(.keyDown, code: 12) == .passed, "the replaced tap claims nothing")
    capture.setClaimsKeys(true)
    let secondTap = try #require(installer.tap)
    #expect(await secondTap.deliver(.keyDown, code: 12) == .consumed)
    await second.delivered.wait()
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

  /// Returns once main has run everything queued on it before this call.
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
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
  private(set) var tap: RecordedTap?
  var isInstalled: Bool { tap != nil }

  func install(
    eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, context: ScreenSharingKeyboardTapContext
  ) -> (() -> Void)? {
    installs += 1
    guard available else { return nil }
    mask = eventsOfInterest
    let tap = RecordedTap(callback: callback, context: context)
    context.setReenable { [reenables = tap.reenables] in reenables.signal() }
    self.tap = tap
    return { [weak self] in
      guard let self else { return }
      teardowns += 1
      self.tap = nil
    }
  }
}

/// One registered callback, invoked from a background thread as the tap's thread would.
private final class RecordedTap: Sendable {
  enum Outcome: Sendable { case consumed, passed }
  nonisolated(unsafe) let callback: CGEventTapCallBack
  let context: ScreenSharingKeyboardTapContext
  let reenables = TestSignal()

  init(callback: CGEventTapCallBack, context: ScreenSharingKeyboardTapContext) {
    self.callback = callback; self.context = context
  }

  func deliver(_ type: CGEventType, code: UInt16, injected: Bool = false, withContext: Bool = true) async -> Outcome {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInteractive).async {
        continuation.resume(
          returning: self.deliverBlocking(type, code: code, injected: injected, withContext: withContext))
      }
    }
  }

  /// On the calling thread; the callback never waits for main, so main can call it too.
  func deliverBlocking(_ type: CGEventType, code: UInt16, injected: Bool = false, withContext: Bool = true) -> Outcome {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp),
      let proxy = CGEventTapProxy(bitPattern: 1)
    else { return .passed }
    event.flags = []  // not whatever modifiers happen to be held on this Mac
    if injected { event.setIntegerValueField(.eventSourceUserData, value: ScreenSharingInputInjector.eventTag) }
    let context = withContext ? Unmanaged.passUnretained(context).toOpaque() : nil
    let result = withExtendedLifetime(self.context) { callback(proxy, type, event, context) }
    return result == nil ? .consumed : .passed
  }
}

@MainActor
private final class CaptureRecorder {
  private(set) var events: [(type: CGEventType, code: Int64)] = []
  private(set) var interruptions = 0
  let delivered = TestSignal()
  let interrupted = TestSignal()
  lazy var handle: (CGEventType, CGEvent) -> Bool = { [unowned self] type, event in
    events.append((type, event.getIntegerValueField(.keyboardEventKeycode)))
    delivered.signal()
    return true
  }
  lazy var interrupt: () -> Void = { [unowned self] in
    interruptions += 1
    interrupted.signal()
  }
}
