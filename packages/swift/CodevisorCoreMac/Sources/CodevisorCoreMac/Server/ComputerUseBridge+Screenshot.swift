import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

extension ComputerUseBridge {
  struct ScreenshotCapture {
    let data: Data
    let pixelSize: CGSize
    let windowFrame: CGRect
  }

  enum ScreenshotOutcome {
    case captured(ScreenshotCapture)
    case unavailable(String)

    var capture: ScreenshotCapture? {
      if case let .captured(capture) = self { return capture }
      return nil
    }

    var reason: String? {
      if case let .unavailable(reason) = self { return reason }
      return nil
    }
  }

  func screenshot(
    windowID: CGWindowID?,
    fallbackFrame: CGRect?
  ) -> ScreenshotOutcome {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      return .unavailable(
        "Screen Recording permission is not granted to Codevisor; the accessibility tree is the only view of this app."
      )
    }
    guard let windowID else {
      if let capture = fallbackFrame.flatMap({ screenshotRegion(frame: $0) }) {
        return .captured(capture)
      }
      return .unavailable("The app exposes no capturable window.")
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = ScreenshotBox()
    let captureTask = Task {
      defer { semaphore.signal() }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false,
          onScreenWindowsOnly: false
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
          box.fail("The window is no longer shareable.")
          return
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let capturedWindowFrame = window.frame
        let scale = max(1, CGFloat(filter.pointPixelScale))
        configuration.width = max(2, Int((capturedWindowFrame.width * scale).rounded()))
        configuration.height = max(2, Int((capturedWindowFrame.height * scale).rounded()))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: filter,
          configuration: configuration
        )
        guard
          let data = NSBitmapImageRep(cgImage: image).representation(
            using: .png,
            properties: [:]
          )
        else {
          box.fail("The captured image could not be encoded.")
          return
        }
        box.succeed(
          ScreenshotCapture(
            data: data,
            pixelSize: CGSize(width: image.width, height: image.height),
            windowFrame: capturedWindowFrame
          ))
      } catch {
        box.fail(error.localizedDescription)
      }
    }
    if semaphore.wait(timeout: .now() + 10) == .timedOut { captureTask.cancel() }
    let result = box.finish()
    if let capture = result.capture { return .captured(capture) }
    guard windowIsOnVisibleSpace(windowID) else {
      return .unavailable(
        "The window could not be captured: \(result.failure ?? "the capture timed out")."
      )
    }
    if let capture = fallbackFrame.flatMap({ screenshotRegion(frame: $0) }) {
      return .captured(capture)
    }
    return .unavailable(
      "Screen capture failed for the target window: \(result.failure ?? "the capture timed out")."
    )
  }

  private func screenshotRegion(frame: CGRect) -> ScreenshotCapture? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ScreenshotBox()
    SCScreenshotManager.captureImage(in: frame) { image, _ in
      if let image,
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      {
        box.succeed(
          ScreenshotCapture(
            data: data,
            pixelSize: CGSize(width: image.width, height: image.height),
            windowFrame: frame
          ))
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)
    return box.finish().capture
  }
}

func computerUseUncapturableReason(_ visibility: ComputerUseWindowVisibility, appName: String) -> String? {
  switch visibility {
  case .minimized:
    "The window is minimized, so it can't be captured. Restore it with windowAction to see it; accessibility actions still work."
  case .appHidden:
    "\(appName) is hidden, so its window can't be captured. Accessibility actions still work; one that unhides the app reports appBecameVisible."
  case .visible, .otherSpace, .closed:
    nil
  }
}

private final class ScreenshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var capture: ComputerUseBridge.ScreenshotCapture?
  private var failure: String?
  private var finished = false

  func succeed(_ value: ComputerUseBridge.ScreenshotCapture) {
    lock.withLock { if !finished { capture = value } }
  }

  func fail(_ reason: String) {
    lock.withLock { if !finished { failure = reason } }
  }

  func finish() -> (capture: ComputerUseBridge.ScreenshotCapture?, failure: String?) {
    lock.withLock {
      finished = true
      return (capture, failure)
    }
  }
}
