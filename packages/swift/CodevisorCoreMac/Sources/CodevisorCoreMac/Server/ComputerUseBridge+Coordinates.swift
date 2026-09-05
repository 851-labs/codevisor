import AppKit
import ApplicationServices
import Foundation

func computerUseAppScope(_ sessionID: String, _ pid: pid_t) -> String {
  "\(sessionID):app:\(pid)"
}

func computerUseSnapshotScope(_ sessionID: String, _ pid: pid_t, _ windowID: CGWindowID?) -> String {
  "\(computerUseAppScope(sessionID, pid)):window:\(windowID.map(String.init) ?? "none")"
}

func computerUseFramesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
  abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1
    && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
}

extension ComputerUseBridge {
  func currentSnapshot(
    sessionID: String, pid: pid_t, windowID: CGWindowID?, arguments: [String: Any]
  ) throws -> SnapshotRecord {
    let scope = computerUseSnapshotScope(sessionID, pid, windowID)
    let explicit = (arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String
    let (latest, record) = lock.withLock {
      let latest = latestSnapshotIDs[scope]
      return (latest, (explicit ?? latest).flatMap { snapshots[sessionID]?[$0] })
    }
    guard let record, record.pid == pid, record.windowID == windowID,
      explicit == nil || explicit == latest
    else {
      throw BridgeError("Stale snapshot or wrong app/window. Call get_app_state for this window again.")
    }
    return record
  }

  func targetElement(
    sessionID: String, pid: pid_t, windowID: CGWindowID?, arguments: [String: Any]
  ) throws -> ElementRecord? {
    guard let rawID = arguments["elementId"] ?? arguments["element_index"] else { return nil }
    let snapshot = try currentSnapshot(sessionID: sessionID, pid: pid, windowID: windowID, arguments: arguments)
    guard let record = snapshot.elements[String(describing: rawID)],
      elementIdentity(record.element) == record.identity
    else {
      throw BridgeError("Unknown or changed element. Call get_app_state again; do not reuse this index.")
    }
    return record
  }

  func elementIdentity(_ element: AXUIElement) -> String {
    var attributes = [
      kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute,
    ]
    if stringAttribute(element, kAXRoleAttribute) == "AXStaticText" { attributes.append(kAXValueAttribute) }
    return
      attributes
      .map { stringAttribute(element, $0) ?? "" }.joined(separator: "\u{1f}")
  }

  /// Resolve against the live window only after foreground activation. A moved
  /// or resized window invalidates pixels; silently clamping them can hit its title bar.
  func screenPoint(
    window: AXUIElement, windowID: CGWindowID?, target: ElementRecord?,
    sessionID: String, arguments: [String: Any]
  ) throws -> CGPoint {
    var pid: pid_t = 0
    AXUIElementGetPid(window, &pid)
    let snapshot = try currentSnapshot(sessionID: sessionID, pid: pid, windowID: windowID, arguments: arguments)
    guard computerUseSnapshotMatchesWindow(snapshotWindowID: snapshot.windowID, targetWindowID: windowID),
      let currentFrame = frame(of: window), let observedFrame = snapshot.windowFrame,
      computerUseFramesMatch(currentFrame, observedFrame)
    else { throw BridgeError("The window moved or resized. Capture a new state before clicking or dragging.") }
    if let target {
      guard let observed = target.frame, let reported = frame(of: target.element) else {
        throw BridgeError("The element has no pointer target. Observe the app again.")
      }
      let flipped = windowID.map { id in lock.withLock { flippedContentWindows[id] == true } } ?? false
      let live =
        flipped
        ? correctedFrame(
          of: target.element, reported: reported,
          application: AXUIElementCreateApplication(pid), windowFrame: currentFrame) : reported
      guard computerUseFramesMatch(observed, live), currentFrame.intersects(live)
      else { throw BridgeError("The element moved or is offscreen. Observe it again before pointer input.") }
      return CGPoint(x: live.midX, y: live.midY)
    }
    guard let size = snapshot.screenshotPixelSize,
      let x = double(arguments["x"]), let y = double(arguments["y"]),
      x.isFinite, y.isFinite, x >= 0, y >= 0, x < size.width, y < size.height
    else {
      throw BridgeError("Coordinates must be inside this snapshot's screenshot, in pixels. Capture a screenshot first.")
    }
    return computerUseScreenshotPoint(x: x, y: y, screenshotPixelSize: size, windowFrame: currentFrame)
  }

  func dragPoint(
    prefix: String, window: AXUIElement, windowID: CGWindowID?,
    sessionID: String, arguments: [String: Any]
  ) throws -> CGPoint {
    var pointArgs = arguments
    pointArgs.removeValue(forKey: "element_index")
    pointArgs.removeValue(forKey: "elementId")
    if let id = arguments[prefix + "_element_index"] ?? arguments[prefix + "ElementId"] {
      pointArgs["element_index"] = id
    }
    pointArgs["x"] = arguments[prefix + "_x"] ?? arguments[prefix + "X"]
    pointArgs["y"] = arguments[prefix + "_y"] ?? arguments[prefix + "Y"]
    var pid: pid_t = 0
    AXUIElementGetPid(window, &pid)
    let target = try targetElement(sessionID: sessionID, pid: pid, windowID: windowID, arguments: pointArgs)
    guard target == nil || (pointArgs["x"] == nil && pointArgs["y"] == nil) else {
      throw BridgeError("Each drag endpoint must use an element or pixel coordinates, not both.")
    }
    return try screenPoint(
      window: window, windowID: windowID, target: target, sessionID: sessionID, arguments: pointArgs)
  }
}

func computerUseScreenshotPoint(
  x: Double,
  y: Double,
  screenshotPixelSize: CGSize?,
  windowFrame: CGRect
) -> CGPoint {
  let xScale = screenshotPixelSize.map { windowFrame.width / max($0.width, 1) } ?? 1
  let yScale = screenshotPixelSize.map { windowFrame.height / max($0.height, 1) } ?? 1
  return CGPoint(
    x: windowFrame.minX + x * xScale,
    y: windowFrame.minY + y * yScale
  )
}

/// Mirrors a frame vertically inside its window. Some apps publish their
/// content in view space (bottom-left origin) instead of screen space, so a
/// control near the bottom is reported near the top; this is the correction.
func computerUseMirroredFrame(_ frame: CGRect, in windowFrame: CGRect) -> CGRect {
  CGRect(
    x: frame.minX,
    y: windowFrame.minY + windowFrame.maxY - frame.maxY,
    width: frame.width,
    height: frame.height
  )
}

/// Whether a window's contents are published upside down, decided by asking
/// the system what is actually at each reported position. Only a decisive
/// majority counts: apps whose hit-testing resolves to something else
/// entirely (web views) score neither way and must be left alone rather than
/// "corrected" into nonsense.
func computerUseFramesAreFlipped(directHits: Int, mirroredHits: Int, samples: Int) -> Bool {
  guard samples >= 3, mirroredHits >= 3 else { return false }
  return mirroredHits > directHits * 2
}

/// A snapshot can only map screenshot coordinates onto the window it captured.
/// Unknown window identity cannot authorize a coordinate mapping.
func computerUseSnapshotMatchesWindow(
  snapshotWindowID: CGWindowID?,
  targetWindowID: CGWindowID?
) -> Bool {
  guard let snapshotWindowID, let targetWindowID else { return false }
  return snapshotWindowID == targetWindowID
}

/// The pixel size a screenshot of `windowFrame` would have on a display with
/// `pointPixelScale`, mirroring the capture configuration in `screenshot`.
func computerUseDerivedScreenshotPixelSize(
  windowFrame: CGRect,
  pointPixelScale: CGFloat
) -> CGSize {
  let scale = max(1, pointPixelScale)
  return CGSize(
    width: (windowFrame.width * scale).rounded(),
    height: (windowFrame.height * scale).rounded()
  )
}

func computerUseScreenshotFrame(
  screenFrame: CGRect,
  screenshotPixelSize: CGSize?,
  windowFrame: CGRect?
) -> CGRect? {
  guard let windowFrame else { return nil }
  let xScale = screenshotPixelSize.map { max($0.width, 1) / max(windowFrame.width, 1) } ?? 1
  let yScale = screenshotPixelSize.map { max($0.height, 1) / max(windowFrame.height, 1) } ?? 1
  return CGRect(
    x: (screenFrame.minX - windowFrame.minX) * xScale,
    y: (screenFrame.minY - windowFrame.minY) * yScale,
    width: screenFrame.width * xScale,
    height: screenFrame.height * yScale
  )
}
