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

  /// Why a snapshot has no image. A bare `null` left the model unable to
  /// tell "nothing to see" from "blind", so every failure carries a reason
  /// the model can act on.
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
    // Structured concurrency rather than nested completion handlers: the
    // callback form delivers on a queue this worker may itself be
    // blocking, which silently turned every capture into a ten-second
    // timeout and looked like "macOS cannot capture this window".
    let semaphore = DispatchSemaphore(value: 0)
    let box = ScreenshotBox()
    Task {
      defer { semaphore.signal() }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false,
          onScreenWindowsOnly: false
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
          box.failure = "The window is no longer shareable."
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
          box.failure = "The captured image could not be encoded."
          return
        }
        box.capture = ScreenshotCapture(
          data: data,
          pixelSize: CGSize(width: image.width, height: image.height),
          windowFrame: capturedWindowFrame
        )
      } catch {
        box.failure = error.localizedDescription
      }
    }
    _ = semaphore.wait(timeout: .now() + 10)
    if let capture = box.capture { return .captured(capture) }
    // A region fallback is valid only when the target is on the current
    // Space. Otherwise it would return pixels belonging to whichever
    // unrelated window happens to occupy the same coordinates.
    guard windowIsOnVisibleSpace(windowID) else {
      return .unavailable(
        "The window could not be captured: \(box.failure ?? "the capture timed out")."
      )
    }
    if let capture = fallbackFrame.flatMap({ screenshotRegion(frame: $0) }) {
      return .captured(capture)
    }
    return .unavailable(
      "Screen capture failed for the target window: \(box.failure ?? "the capture timed out")."
    )
  }

  private func screenshotRegion(frame: CGRect) -> ScreenshotCapture? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ScreenshotBox()
    SCScreenshotManager.captureImage(in: frame) { image, _ in
      if let image,
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      {
        box.capture = ScreenshotCapture(
          data: data,
          pixelSize: CGSize(width: image.width, height: image.height),
          windowFrame: frame
        )
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)
    return box.capture
  }
}

private final class ScreenshotBox: @unchecked Sendable {
  var capture: ComputerUseBridge.ScreenshotCapture?
  /// Why the capture produced nothing, so the caller can say so instead of
  /// reporting a bare absence.
  var failure: String?
}
