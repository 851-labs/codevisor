import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
  func targetElement(sessionID: String, arguments: [String: Any]) throws -> ElementRecord? {
    let explicitSnapshotID = (arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String
    let snapshotID = explicitSnapshotID ?? lock.withLock { latestSnapshotIDs[sessionID] }
    let elementID = (arguments["elementId"] ?? arguments["element_index"]).map {
      String(describing: $0)
    }
    guard let snapshotID, let elementID, !elementID.isEmpty else { return nil }
    guard let record = lock.withLock({ snapshots[sessionID]?[snapshotID]?.elements[elementID] }) else {
      throw BridgeError("Unknown or expired element; call get_app_state again")
    }
    return record
  }

  func screenPoint(
    window: AXUIElement,
    windowID: CGWindowID?,
    target: ElementRecord?,
    sessionID: String,
    arguments: [String: Any]
  ) throws -> CGPoint {
    if let frame = target?.frame { return CGPoint(x: frame.midX, y: frame.midY) }
    guard let frame = frame(of: window), let x = double(arguments["x"]), let y = double(arguments["y"])
    else { throw BridgeError("A current element or screenshot x/y coordinate is required") }
    return screenshotPoint(
      x: x,
      y: y,
      fallbackWindowFrame: frame,
      sessionID: sessionID,
      windowID: windowID,
      snapshotID: (arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String
    )
  }

  func dragPoint(
    prefix: String,
    window: AXUIElement,
    windowID: CGWindowID?,
    sessionID: String,
    arguments: [String: Any]
  ) throws -> CGPoint {
    let camelKey = prefix + "ElementId"
    let snakeKey = prefix + "_element_index"
    if let rawID = arguments[camelKey] ?? arguments[snakeKey] {
      let id = String(describing: rawID)
      let snapshotID =
        ((arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String)
        ?? lock.withLock({ latestSnapshotIDs[sessionID] })
      if !id.isEmpty, let snapshotID,
        let frame = lock.withLock({ snapshots[sessionID]?[snapshotID]?.elements[id]?.frame })
      {
        return CGPoint(x: frame.midX, y: frame.midY)
      }
    }
    guard let frame = frame(of: window),
      let x = double(arguments[prefix + "X"] ?? arguments[prefix + "_x"]),
      let y = double(arguments[prefix + "Y"] ?? arguments[prefix + "_y"])
    else { throw BridgeError("Drag endpoints require current elements or coordinates") }
    return screenshotPoint(
      x: x,
      y: y,
      fallbackWindowFrame: frame,
      sessionID: sessionID,
      windowID: windowID,
      snapshotID: (arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String
    )
  }

  private func screenshotPoint(
    x: Double,
    y: Double,
    fallbackWindowFrame: CGRect,
    sessionID: String,
    windowID: CGWindowID?,
    snapshotID: String?
  ) -> CGPoint {
    let snapshot =
      snapshotID.flatMap { id in
        lock.withLock { snapshots[sessionID]?[id] }
      }
      ?? lock.withLock {
        latestSnapshotIDs[sessionID].flatMap { snapshots[sessionID]?[$0] }
      }
    // Coordinates are pixels in a specific snapshot's screenshot. A
    // snapshot of a different window cannot map this action's coordinates.
    if let snapshot,
      computerUseSnapshotMatchesWindow(
        snapshotWindowID: snapshot.windowID,
        targetWindowID: windowID
      )
    {
      // A nil pixel size here means the snapshot's accessibility frames
      // were reported unscaled (no screenshot), so 1x is correct.
      return computerUseScreenshotPoint(
        x: x,
        y: y,
        screenshotPixelSize: snapshot.screenshotPixelSize,
        windowFrame: snapshot.windowFrame ?? fallbackWindowFrame
      )
    }
    // Without a trustworthy snapshot the coordinates still originate from
    // a screenshot in device pixels. Assuming 1x would double every offset
    // on Retina displays, so derive the window's real display scale.
    return computerUseScreenshotPoint(
      x: x,
      y: y,
      screenshotPixelSize: computerUseDerivedScreenshotPixelSize(
        windowFrame: fallbackWindowFrame,
        pointPixelScale: displayPointPixelScale(for: fallbackWindowFrame)
      ),
      windowFrame: fallbackWindowFrame
    )
  }

  /// Point-to-pixel scale of the display that shows most of `frame`, in the
  /// same global top-left coordinate space CG windows use. Falls back to the
  /// main display so an offscreen frame still resolves to a real scale.
  private func displayPointPixelScale(for frame: CGRect) -> CGFloat {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var matched: UInt32 = 0
    var resolved = CGMainDisplayID()
    if CGGetDisplaysWithRect(frame, UInt32(displays.count), &displays, &matched) == .success,
      matched > 0
    {
      resolved =
        displays.prefix(Int(matched)).max { lhs, rhs in
          let lhsOverlap = CGDisplayBounds(lhs).intersection(frame)
          let rhsOverlap = CGDisplayBounds(rhs).intersection(frame)
          return lhsOverlap.width * lhsOverlap.height
            < rhsOverlap.width * rhsOverlap.height
        } ?? resolved
    }
    guard let mode = CGDisplayCopyDisplayMode(resolved), mode.width > 0 else { return 1 }
    return max(1, CGFloat(mode.pixelWidth) / CGFloat(mode.width))
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
    x: min(
      windowFrame.maxX - 0.5,
      max(windowFrame.minX + 0.5, windowFrame.minX + x * xScale)
    ),
    y: min(
      windowFrame.maxY - 0.5,
      max(windowFrame.minY + 0.5, windowFrame.minY + y * yScale)
    )
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
/// Unknown identity on either side keeps the previous permissive behavior.
func computerUseSnapshotMatchesWindow(
  snapshotWindowID: CGWindowID?,
  targetWindowID: CGWindowID?
) -> Bool {
  guard let snapshotWindowID, let targetWindowID else { return true }
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
