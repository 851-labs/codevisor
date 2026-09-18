import CoreMedia
import Foundation
@preconcurrency import WebRTC
import ScreenSharing

/// Capture feeds WebRTC directly on its capture queue. The lock serializes
/// admission with shutdown; no per-frame tasks accumulate on the main actor.
public final class ScreenSharingFrameSender: ScreenSharingFrameSink, @unchecked Sendable {
  private let source: RTCVideoSource
  private let capturer: RTCVideoCapturer
  private let metrics: ScreenSharingMetrics
  private let idleMonitor: ScreenSharingSourceIdleMonitor
  private let lock = NSLock()
  private var active = true
  private var captureSuspended = false
  private var refreshFrames = ScreenSharingRefreshFrameStore()
  private var expectedSize: (width: Int, height: Int)?
  private var onActivity: (@Sendable () -> Void)?

  init(source: RTCVideoSource, metrics: ScreenSharingMetrics, idleMonitor: ScreenSharingSourceIdleMonitor) {
    self.source = source
    self.metrics = metrics
    self.idleMonitor = idleMonitor
    capturer = RTCVideoCapturer(delegate: source)
  }

  /// Invoked once per idle-to-active transition, outside the sender's lock.
  func onActivity(_ callback: (@Sendable () -> Void)?) { lock.withLock { onActivity = callback } }

  public func push(_ frame: ScreenSharingVideoFrame) {
    let activated: (@Sendable () -> Void)? = lock.withLock {
      guard active, !captureSuspended else { return nil }
      if let expectedSize,
        CVPixelBufferGetWidth(frame.pixelBuffer) != expectedSize.width
          || CVPixelBufferGetHeight(frame.pixelBuffer) != expectedSize.height
      {
        metrics.increment("captureTransitionDrops"); return nil
      }
      let wasHolding = refreshFrames.isHolding
      guard let submission = refreshFrames.capture(frame) else {
        metrics.increment("captureTimestampDrops"); return nil
      }
      // New content in a (possibly recycled) buffer: identify it before WebRTC sees it.
      ScreenSharingFrameIdentity.attach(sourceTimestampNs: frame.timestampNs, to: frame.pixelBuffer)
      metrics.increment("capturedFrames")
      // Cache ownership events (not a reference balance): a fill of an empty
      // cache, or a replacement that releases the previously held buffer.
      metrics.increment(wasHolding ? "refreshCacheReplacements" : "refreshCacheFills")
      metrics.label("latestCapturedTimestampNs", String(frame.timestampNs))
      let started = ScreenSharingMetrics.nowNs
      metrics.event("captureArrivalInterval", atNanoseconds: started)
      metrics.event("captureTimestampInterval", atNanoseconds: frame.timestampNs)
      let activated = idleMonitor.recordSubmission(timestampNs: frame.timestampNs, nowNs: started)
      submit(submission)
      metrics.observe("capturePush", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
      return activated ? onActivity : nil
    }
    activated?()
  }

  /// Transition the source format before updating SCK. Frames still arriving
  /// at the old size are expendable raw frames and never enter the encoder.
  public func configure(_ configuration: ScreenSharingVideoConfiguration) {
    lock.withLock {
      if refreshFrames.isHolding { metrics.increment("refreshCacheReleases") }
      refreshFrames.clear()
      expectedSize = (configuration.width, configuration.height)
      source.adaptOutputFormat(
        toWidth: Int32(configuration.width), height: Int32(configuration.height),
        fps: Int32(configuration.framesPerSecond))
    }
  }

  func refreshLatest(reason: String = "request") {
    lock.withLock {
      guard active else { return }
      let now = CMTimeConvertScale(
        CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default)
      guard let frame = refreshFrames.refresh(nowNs: now.value) else { return }
      metrics.increment("refreshFrames")
      metrics.trace(
        "refreshSubmission",
        "\(ScreenSharingMetrics.nowNs) \(reason) ts=\(frame.timestampNs) id=\(frame.sourceTimestampNs ?? -1)")
      submit(frame)
    }
  }

  /// Probe-only suspension keeps the same cached frame available for recovery.
  public func suspendCaptureDelivery() { lock.withLock { captureSuspended = true } }

  func stop() {
    lock.withLock {
      active = false
      if refreshFrames.isHolding { metrics.increment("refreshCacheReleases") }
      refreshFrames.clear()
      onActivity = nil
    }
  }

  /// Whether the one-frame cache currently owns a buffer (diagnostic).
  public var isHoldingCachedFrame: Bool { lock.withLock { refreshFrames.isHolding } }

  private func submit(_ frame: ScreenSharingVideoFrame) {
    source.capturer(
      capturer,
      didCapture: RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer), rotation: ._0, timeStampNs: frame.timestampNs))
  }
}
