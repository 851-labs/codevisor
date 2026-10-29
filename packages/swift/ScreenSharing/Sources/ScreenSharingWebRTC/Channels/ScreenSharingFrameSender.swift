import CoreMedia
import Foundation
@preconcurrency import WebRTC
import ScreenSharing

public final class ScreenSharingFrameSender: ScreenSharingFrameSink, @unchecked Sendable {
  private var media: (source: RTCVideoSource, capturer: RTCVideoCapturer)?
  private let releaseQueue: DispatchQueue?
  private let metrics: ScreenSharingMetrics
  private let idleMonitor: ScreenSharingSourceIdleMonitor
  private let captureArrivals: ScreenSharingCaptureArrivals
  private let lock = NSLock()
  private var active = true
  private var refreshFrames = ScreenSharingRefreshFrameStore()
  private var expectedSize: (width: Int, height: Int)?
  private var onActivity: (@Sendable () -> Void)?

  init(
    source: RTCVideoSource, metrics: ScreenSharingMetrics, idleMonitor: ScreenSharingSourceIdleMonitor,
    captureArrivals: ScreenSharingCaptureArrivals, releaseQueue: DispatchQueue? = nil
  ) {
    media = (source, RTCVideoCapturer(delegate: source))
    self.metrics = metrics
    self.idleMonitor = idleMonitor
    self.captureArrivals = captureArrivals
    self.releaseQueue = releaseQueue
  }

  func onActivity(_ callback: (@Sendable () -> Void)?) { lock.withLock { onActivity = callback } }

  public func push(_ frame: ScreenSharingVideoFrame) {
    let arrivedNs = ScreenSharingMetrics.nowNs
    let activated: (@Sendable () -> Void)? = lock.withLock {
      guard active else { return nil }
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
      ScreenSharingFrameIdentity.attach(sourceTimestampNs: frame.timestampNs, to: frame.pixelBuffer)
      captureArrivals.record(sourceTimestampNs: frame.timestampNs, arrivedNs: arrivedNs)
      metrics.increment("capturedFrames")
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

  public func configure(_ configuration: ScreenSharingVideoConfiguration) {
    lock.withLock {
      if refreshFrames.isHolding { metrics.increment("refreshCacheReleases") }
      refreshFrames.clear()
      expectedSize = (configuration.width, configuration.height)
      media?.source.adaptOutputFormat(
        toWidth: Int32(configuration.width), height: Int32(configuration.height),
        fps: Int32(configuration.framesPerSecond))
    }
  }

  func refreshLatest() {
    lock.withLock {
      guard active else { return }
      let now = CMTimeConvertScale(
        CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default)
      guard let frame = refreshFrames.refresh(nowNs: now.value) else { return }
      metrics.increment("refreshFrames")
      submit(frame)
    }
  }

  func stop() {
    let released = lock.withLock {
      active = false
      if refreshFrames.isHolding { metrics.increment("refreshCacheReleases") }
      refreshFrames.clear()
      onActivity = nil
      defer { media = nil }
      return media.map { ReleasedMedia(source: $0.source, capturer: $0.capturer) }
    }
    if let released, let releaseQueue { releaseQueue.async { withExtendedLifetime(released) {} } }
  }

  private struct ReleasedMedia: @unchecked Sendable {
    let source: RTCVideoSource
    let capturer: RTCVideoCapturer
  }

  public var isHoldingCachedFrame: Bool { lock.withLock { refreshFrames.isHolding } }

  private func submit(_ frame: ScreenSharingVideoFrame) {
    guard let (source, capturer) = media else { return }
    source.capturer(
      capturer,
      didCapture: RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer), rotation: ._0, timeStampNs: frame.timestampNs))
  }
}
