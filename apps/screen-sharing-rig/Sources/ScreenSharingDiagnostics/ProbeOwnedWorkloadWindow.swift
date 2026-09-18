import AppKit
import ScreenSharing
import CoreGraphics

/// The diagnostic's one owned workload window, the only thing its
/// ScreenCaptureKit stream may capture: exact backing-pixel size at the main
/// display's top-left corner, normal level, never activated, never key, ignores
/// input, no presentation-option or Space changes, never touches other windows.
/// Its lifecycle is finite and recorded: show → ready (first draw completed)
/// → capturing → optional animation pause (static content stays captured)
/// → capture stopped → closed.
/// The owned window can never become key or main, so showing it steals
/// nothing from the console user's session.
@MainActor
package final class OwnedWorkloadWindow: NSWindow {
  /// Off by default: the workload never takes focus on a desktop someone uses. A rig host on a virtual
  /// display turns it on so injected key events can reach the workload's `keyDown`.
  package var acceptsKeys = false
  package override var canBecomeKey: Bool { acceptsKeys }
  package override var canBecomeMain: Bool { acceptsKeys }
  package override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
package final class ProbeOwnedWorkloadWindow {
  package let window: OwnedWorkloadWindow
  package let view: WorkloadView
  package let rasterWidth: Int
  package let rasterHeight: Int
  package let recordDrawTimes: Bool
  private let gate = ScreenSharingFirstDrawGate()
  public private(set) var session: ScreenSharingOwnedWindowSession!
  /// Bounded named snapshots: each label is stored once (overwritten if taken
  /// again) as soon as it is taken, so pre-start facts survive a later throw.
  public private(set) var snapshots: [String: [String: Any]] = [:]

  /// `stopCapture` stops the stream this window feeds; the session awaits it on
  /// every path where the stream may have started before hiding the window.
  /// `recordDrawTimes` is the explicit opt-in for the bounded first-draw-start
  /// record (off by default; nothing is retained otherwise).
  /// `screen` places the window on a specific display (for example a virtual one); the main display otherwise.
  package init(
    configuration: ScreenSharingVideoConfiguration, recordDrawTimes: Bool = false, screen: NSScreen? = nil,
    stopCapture: @escaping @MainActor () async throws -> Void
  )
    throws
  {
    guard let screen = screen ?? NSScreen.main else {
      throw ScreenSharingError.unavailable("No desktop display for the owned workload window.")
    }
    let painter = try ProbeDesktopPainter.make(
      width: configuration.width, height: configuration.height, fps: configuration.framesPerSecond)
    rasterWidth = configuration.width
    rasterHeight = configuration.height
    let view = WorkloadView(painter: painter, recordDrawTimes: recordDrawTimes)
    self.recordDrawTimes = recordDrawTimes
    self.view = view
    let size = NSSize(
      width: Double(configuration.width) / screen.backingScaleFactor,
      height: Double(configuration.height) / screen.backingScaleFactor)
    let frame = NSRect(
      x: screen.frame.minX, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    let window = OwnedWorkloadWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.title = "Codevisor · Screen Sharing Probe Owned Workload"
    window.level = .normal
    window.ignoresMouseEvents = true
    window.isExcludedFromWindowsMenu = true
    window.contentView = view
    self.window = window
    let gate = self.gate
    view.onFirstDraw = { gate.signal() }
    session = ScreenSharingOwnedWindowSession(
      show: {
        // On screen without activating the app or taking key/main.
        window.orderFrontRegardless()
        view.start()
      },
      hide: {
        view.stop()
        window.orderOut(nil)
      },
      stopCapture: stopCapture)
  }

  package var windowID: UInt32 { UInt32(max(0, window.windowNumber)) }
  package var lifecycle: ScreenSharingOwnedWorkloadLifecycle { session.lifecycle }

  /// Shows the window, waits for its first completed draw CALL — not a display
  /// presentation — (deadline = deadlock guard; cancellation, timeout or
  /// teardown resumes the wait once and blocks capture), confirms visibility,
  /// then starts capture through `startCapture`. Any failure hides this window
  /// once and rethrows; no lifecycle evidence is invented. Returns the
  /// readiness record.
  package func start(timeoutSeconds: Double, startCapture: () async throws -> Void) async throws -> [String: Any] {
    var ready: [String: Any] = [:]
    try await session.start(
      ready: { [self] in
        try await gate.wait(timeout: .seconds(timeoutSeconds)) { try await Task.sleep(for: $0) }
        guard window.isVisible, window.windowNumber > 0, let firstDrawStartedAt = view.firstDrawStartedAt,
          let firstDrawCompletedAt = view.firstDrawCompletedAt
        else {
          throw ScreenSharingError.unavailable("Owned workload window is not visible.")
        }
        ready = [
          "windowID": window.windowNumber, "processID": ProcessInfo.processInfo.processIdentifier,
          "framePoints": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
          "contentWidthPoints": view.bounds.width, "contentHeightPoints": view.bounds.height,
          "backingScaleFactor": window.backingScaleFactor,
          "rasterWidth": rasterWidth, "rasterHeight": rasterHeight,
          "displayID": (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) ?? 0,
          "level": window.level.rawValue, "ignoresMouseEvents": window.ignoresMouseEvents,
          "activated": NSApplication.shared.isActive, "isKeyWindow": window.isKeyWindow,
          "startedAtSeconds": view.startedAt,
          "firstDrawStartedAtSeconds": firstDrawStartedAt, "firstDrawCompletedAtSeconds": firstDrawCompletedAt,
          "readinessMeaning": "first draw(_:) call completed on a visible window; not a display presentation time",
        ]
        ready["observationAtReadiness"] = observation(
          "readiness (after first draw and visibility check, before capture start)")
      },
      startCapture: startCapture)
    ready["readyAtUptimeNs"] = session.lifecycle.timestampsNs[.ready] ?? 0
    return ready
  }

  /// Stops the animation and freezes the frame code; the window and its last
  /// frame stay on screen and stay captured. Returns the boundary record.
  package func pauseAnimation() throws -> [String: Any] {
    try session.pauseWorkload { view.pause() }
    return [
      "pausedAtSeconds": CACurrentMediaTime(), "pausedAtUptimeNs": session.lifecycle.timestampsNs[.pauseWorkload] ?? 0,
      "observation": observation("workload pause"),
      "drawCalls": view.drawCalls, "frozenCode": view.frozenCode ?? -1, "lastDrawnCode": view.sequence,
      "frozen": view.isPaused,
      "frozenCodeMeaning":
        "the last DRAWN frame code, frozen as drawn (not re-derived from time) and held for every later redraw; not evidence of what the display showed",
      "windowStillVisible": window.isVisible,
    ]
  }

  /// Stops the stream through the session so success or failure is preserved.
  @discardableResult
  package func stopCapture() async -> Bool { await session.stopCapture() }

  /// The single cleanup used on every exit path; hides only this window, once.
  @discardableResult
  package func cleanUp() -> ScreenSharingOwnedWorkloadLifecycle.CleanupOutcome {
    // Resolve a still-pending readiness wait by teardown (not task cancellation).
    gate.teardown()
    return session.finish()
  }

  /// One timestamped, read-only observation of the facts the missing-delivery
  /// investigation needs. Nothing here prompts, activates, or changes state:
  /// `CGPreflightScreenCaptureAccess()` is the GLOBAL non-prompting preflight
  /// (false does not prove this owned-window filter must be refused); the CG
  /// window record is restricted to this exact window number and pid; the
  /// display predicates are for the window's own screen (unknown if none).
  /// Coordinate conventions are kept raw and the single conversion is labelled.
  @discardableResult
  package func observation(_ label: String) -> [String: Any] {
    let record = takeObservation(label)
    snapshots[label] = record
    return record
  }

  private func takeObservation(_ label: String) -> [String: Any] {
    var record: [String: Any] = [
      "label": label, "atUptimeNs": ScreenSharingMetrics.nowNs, "atMediaTimeSeconds": CACurrentMediaTime(),
      "screenCapturePreflight": CGPreflightScreenCaptureAccess(),
      "screenCapturePreflightMeaning":
        "global non-prompting CGPreflightScreenCaptureAccess(); false is not proof that this owned-window filter must be refused",
      "activationPolicy": NSApplication.shared.activationPolicy().rawValue,
      "appIsActive": NSApplication.shared.isActive, "appIsHidden": NSApplication.shared.isHidden,
      "windowNumber": window.windowNumber, "processID": ProcessInfo.processInfo.processIdentifier,
      "windowIsVisible": window.isVisible, "windowOcclusionVisible": window.occlusionState.contains(.visible),
      "windowIsOnActiveSpace": window.isOnActiveSpace, "windowLevel": window.level.rawValue,
      "windowFrameCocoaPoints": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
      "windowFrameCocoaConvention": "NSWindow.frame: points, origin bottom-left of the main display (raw)",
      "backingScaleFactor": window.backingScaleFactor,
    ]
    let mainBounds = CGDisplayBounds(CGMainDisplayID())
    let converted = ScreenSharingOwnedWindowGeometry.cocoaToTopLeft(
      .init(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: window.frame.height),
      mainDisplayHeight: mainBounds.height)
    record["windowFrameTopLeftConverted"] = [converted.x, converted.y, converted.width, converted.height]
    record["windowFrameTopLeftConversion"] =
      "y' = mainDisplayHeight - (y + height) with CGDisplayBounds(CGMainDisplayID()).height = \(mainBounds.height)"
    // Own-window CG record: exact window number AND pid, or an explicit non-result.
    let number = CGWindowID(max(0, window.windowNumber))
    var entries: [ScreenSharingOwnedWindowGeometry.WindowListEntry]?
    if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]] {
      entries = []
      for item in list {
        guard let itemNumber = item[kCGWindowNumber as String] as? UInt32 else { continue }
        let owner = item[kCGWindowOwnerPID as String] as? Int32  // may be unreported
        var bounds: ScreenSharingOwnedWindowGeometry.Rect?
        if let dictionary = item[kCGWindowBounds as String] as? [String: Double], let x = dictionary["X"],
          let y = dictionary["Y"], let width = dictionary["Width"], let height = dictionary["Height"]
        {
          bounds = .init(x: x, y: y, width: width, height: height)
        }
        entries?.append(
          .init(
            number: itemNumber, ownerPID: owner, bounds: bounds, layer: item[kCGWindowLayer as String] as? Int,
            isOnscreen: item[kCGWindowIsOnscreen as String] as? Bool, alpha: item[kCGWindowAlpha as String] as? Double))
      }
    }
    switch ScreenSharingOwnedWindowGeometry.ownWindow(
      in: entries, number: number, pid: ProcessInfo.processInfo.processIdentifier)
    {
    case .found(let entry):
      record["cgWindowRecord"] = [
        "number": entry.number, "ownerPID": entry.ownerPID,
        "boundsTopLeftPoints": entry.bounds.map { [$0.x, $0.y, $0.width, $0.height] } ?? "unreported",
        "boundsConvention": "kCGWindowBounds: points, origin top-left of the main display (raw)",
        "layer": entry.layer ?? "unreported", "isOnscreen": entry.isOnscreen ?? "unreported",
        "alpha": entry.alpha ?? "unreported",
      ]
    case .queryUnavailable: record["cgWindowRecord"] = "query unavailable (CGWindowListCopyWindowInfo returned nil)"
    case .absent: record["cgWindowRecord"] = "absent (query succeeded; no entry with this window number)"
    case .ownerUnreported:
      record["cgWindowRecord"] = "exact window number present but owner pid unreported; fields not persisted"
    case .ownerMismatch(let pid): record["cgWindowRecord"] = "owner mismatch: reported pid \(pid); fields not persisted"
    case .duplicate(let count): record["cgWindowRecord"] = "duplicate: \(count) entries; fields not persisted"
    }
    // Display predicates for the window's own screen; a missing screen is unknown.
    if let screen = window.screen,
      let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    {
      let bounds = CGDisplayBounds(displayID)
      record["display"] = [
        "displayID": displayID, "isActive": CGDisplayIsActive(displayID) != 0,
        "isAsleep": CGDisplayIsAsleep(displayID) != 0,
        "isOnline": CGDisplayIsOnline(displayID) != 0, "isMain": CGDisplayIsMain(displayID) != 0,
        "screenFrameCocoaPoints": [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height],
        "displayBoundsTopLeftPoints": [bounds.minX, bounds.minY, bounds.width, bounds.height],
      ]
    } else {
      record["display"] = "unknown (window has no screen)"
    }
    return record
  }

  /// The owned workload's draw-timestamp report in the SAME schema as the
  /// desktop workload report the image-age analyzer consumes (`drawSamples`
  /// of `{code, startedAtSeconds}` + `drawSamplesTruncated`), plus the
  /// owned-window facts. Nil unless recording was opted in.
  /// `mediaMeasuredSeconds` is the probe's media measurement (its origin is the
  /// media-ready boundary); the workload's own interval is computed here from
  /// its start (`WorkloadView.start()` sets `startedAt` before scheduling the
  /// first draw; the first draw start is recorded separately in the readiness
  /// record) to now, so the two origins are never mixed.
  package func workloadTimesReport(mediaMeasuredSeconds: Double) -> [String: Any]? {
    guard recordDrawTimes else { return nil }
    let endedAt = CACurrentMediaTime()
    return [
      "kind": "owned-workload",
      "source": "owned window captured through ScreenCaptureKit (currentProcess selection)",
      "timingScope": "AppKit draw-call starts and frozen-code pause; not physical presentation or input-to-photon",
      "rasterWidth": rasterWidth, "rasterHeight": rasterHeight,
      "windowWidthPoints": view.bounds.width, "windowHeightPoints": view.bounds.height,
      "backingScaleFactor": window.backingScaleFactor, "requestedFPS": view.fps,
      "startedAtSeconds": view.startedAt, "endedAtSeconds": endedAt, "elapsedSeconds": endedAt - view.startedAt,
      "mediaMeasuredSeconds": mediaMeasuredSeconds,
      "origins":
        "startedAtSeconds/endedAtSeconds/elapsedSeconds: this workload's start (set before its first draw is scheduled) to report time (CACurrentMediaTime); firstDrawStartedAtSeconds lives in the readiness record; mediaMeasuredSeconds: the probe's media measurement from its media-ready boundary",
      "drawCalls": view.drawCalls,
      "lastSequence": view.sequence, "frozenCode": view.frozenCode ?? -1, "frozen": view.isPaused,
      "responses": 0, "eventSamples": [] as [Any], "eventSamplesTruncated": false,
      "drawSamples": view.drawSamples.map { ["code": $0.code, "startedAtSeconds": $0.startedAtSeconds] },
      "drawSamplesTruncated": view.drawSamplesTruncated,
      "drawSampleLimit": ScreenSharingDrawTimestampRecord.defaultLimit,
    ]
  }

  package var lifecycleRecord: [String: Any] {
    var record = session.record
    record["workloadFrozen"] = view.isPaused
    return record
  }
}
