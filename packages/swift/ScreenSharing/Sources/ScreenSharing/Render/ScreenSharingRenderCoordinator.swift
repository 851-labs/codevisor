import CoreGraphics
import Foundation
import QuartzCore

package protocol ScreenSharingRenderSubmission: Sendable {
  func onCompleted(_ handler: @escaping @Sendable (_ completed: Bool) -> Void)
  func onPresented(_ handler: @escaping @Sendable (_ presentedTime: Double) -> Void)
  func commit()
}

package struct ScreenSharingRenderGeometry: Equatable, Sendable {
  package let clearColor: SIMD4<Double>
  package let drawableSize: CGSize
  package init(clearColor: SIMD4<Double>, drawableSize: CGSize) {
    self.clearColor = clearColor
    self.drawableSize = drawableSize
  }
}

package struct ScreenSharingPreparationRequest: Sendable {
  package let frame: ScreenSharingVideoFrame
  package let isNewFrame: Bool
  package let geometry: ScreenSharingRenderGeometry
  package let queuedAtNs: Int64
  package let auditIdentity: ScreenSharingFrameDeliveryAudit.Identity?
}

package struct ScreenSharingPreparedSubmission: Sendable {
  package let submission: any ScreenSharingRenderSubmission
  package let retained: AnyObject & Sendable
  package let videoSize: CGSize
  package init(submission: any ScreenSharingRenderSubmission, retained: AnyObject & Sendable, videoSize: CGSize) {
    self.submission = submission
    self.retained = retained
    self.videoSize = videoSize
  }
}

package protocol ScreenSharingRenderPreparer: Sendable {
  func prepare(
    _ request: ScreenSharingPreparationRequest,
    completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void)
}

@MainActor
package final class ScreenSharingRenderCoordinator {
  package typealias Hop = @Sendable (_ work: @escaping @Sendable @MainActor () -> Void) -> Void

  package let mailbox: ScreenSharingFrameMailbox
  package let metrics: ScreenSharingMetrics
  package let renderOnArrival: Bool
  package var onFrameSize: ((CGSize) -> Void)? {
    didSet { if stopped { onFrameSize = nil } }
  }
  package var onPresented: ((UInt32) -> Void)? {
    didSet { if stopped { onPresented = nil } }
  }
  package var onFramePresented: ((ScreenSharingPresentedFrame) -> Void)? {
    didSet { if stopped { onFramePresented = nil } }
  }
  package private(set) var inFlight = false
  package var preparationToken: Int? { pending?.token }
  private struct PendingPreparation {
    let token: Int
    let rtpTimestamp: UInt32
    let receivedAt: Double?
    let sourceTimestampNs: Int64?
    let isNewFrame: Bool
    let auditIdentity: ScreenSharingFrameDeliveryAudit.Identity?
  }
  package var audit: ScreenSharingFrameDeliveryAudit?
  private var pending: PendingPreparation?
  private let redrawsOnDemand: Bool
  private var redrawHopPending = false
  package private(set) var stopped = false
  package var isHoldingCachedFrame: Bool { lastFrame != nil }
  private var lastFrame: ScreenSharingVideoFrame?
  private var needsRedraw = false
  private var owedPresentation = false
  private var reportedSize = CGSize.zero
  private var requestDraw: @MainActor () -> Void = {}
  private let hop: Hop
  private var occupancy = 0

  package init(
    mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, renderOnArrival: Bool,
    redrawsOnDemand: Bool = false,
    hop: @escaping Hop = { work in Task { @MainActor in work() } }
  ) {
    self.mailbox = mailbox
    self.metrics = metrics
    self.renderOnArrival = renderOnArrival
    self.redrawsOnDemand = redrawsOnDemand
    self.hop = hop
  }

  package func bind(requestDraw: @escaping @MainActor () -> Void) {
    guard !stopped else { return }
    self.requestDraw = requestDraw
    guard renderOnArrival else { return }
    let hop = hop
    mailbox.onFrameAvailable { [weak self] in hop { self?.arrivalScheduled() } }
  }

  package func arrivalScheduled() {
    guard !stopped else { return }
    requestDraw()
  }

  package func setNeedsRedraw() {
    guard !stopped else { return }
    needsRedraw = true
    guard redrawsOnDemand, !redrawHopPending else { return }
    redrawHopPending = true
    let hop = hop
    hop { [weak self] in self?.redrawScheduled() }
  }

  package func redrawScheduled() {
    redrawHopPending = false
    guard !stopped, needsRedraw, !inFlight else { return }
    requestDraw()
  }

  package func select() -> (frame: ScreenSharingVideoFrame, isNewFrame: Bool)? {
    guard !stopped, !inFlight else { return nil }
    let incoming = mailbox.take()
    guard let frame = incoming ?? (needsRedraw ? lastFrame : nil) else { return nil }
    lastFrame = frame
    needsRedraw = false
    let isNewFrame = incoming != nil || owedPresentation
    owedPresentation = false
    if let audit, incoming != nil {
      audit.record(.selection, frame.deliveryAuditIdentity, rtpTimestamp: frame.rtpTimestamp)
    }
    return (frame, isNewFrame)
  }

  package func deferPresentation() {
    guard !stopped else { return }
    owedPresentation = true
    setNeedsRedraw()
  }

  package func reportSize(_ size: CGSize) {
    guard !stopped, size != reportedSize else { return }
    reportedSize = size
    onFrameSize?(size)
    metrics.label("videoSize", "\(Int(size.width)) × \(Int(size.height))")
  }

  @discardableResult
  package func commit(
    _ submission: any ScreenSharingRenderSubmission, retaining retained: AnyObject & Sendable,
    frame: ScreenSharingVideoFrame,
    isNewFrame: Bool, submittedAt: Double
  ) -> Bool {
    guard !stopped, !inFlight else { return false }
    inFlight = true
    occupancy += 1
    submit(
      submission, retaining: retained, rtpTimestamp: frame.rtpTimestamp, receivedAt: frame.receivedAtSeconds,
      sourceTimestampNs: frame.sourceTimestampNs, isNewFrame: isNewFrame, submittedAt: submittedAt,
      auditIdentity: frame.deliveryAuditIdentity)
    return true
  }

  @discardableResult
  package func prepare(with preparer: any ScreenSharingRenderPreparer, geometry: ScreenSharingRenderGeometry) -> Bool {
    guard let (frame, isNewFrame) = select() else { return false }
    inFlight = true
    occupancy += 1
    let token = occupancy
    pending = .init(
      token: token, rtpTimestamp: frame.rtpTimestamp, receivedAt: frame.receivedAtSeconds,
      sourceTimestampNs: frame.sourceTimestampNs, isNewFrame: isNewFrame, auditIdentity: frame.deliveryAuditIdentity)
    let hop = hop
    preparer.prepare(
      .init(
        frame: frame, isNewFrame: isNewFrame, geometry: geometry, queuedAtNs: ScreenSharingMetrics.nowNs,
        auditIdentity: frame.deliveryAuditIdentity)
    ) { [weak self] prepared in
      hop { self?.finishPreparation(token: token, prepared) }
    }
    return true
  }

  package func finishPreparation(token: Int, _ prepared: ScreenSharingPreparedSubmission?) {
    guard let pending, pending.token == token, occupancy == token else { return }
    self.pending = nil
    if let audit {
      audit.record(
        .preparedReceipt, pending.auditIdentity, rtpTimestamp: pending.rtpTimestamp, valueNs: prepared == nil ? 0 : 1)
    }
    guard !stopped else {
      inFlight = false
      return
    }
    guard let prepared else {
      metrics.increment("renderDrops")
      releaseSlot(occupancy: token)
      if pending.isNewFrame { deferPresentation() }
      return
    }
    reportSize(prepared.videoSize)
    guard !stopped else {
      inFlight = false
      return
    }
    submit(
      prepared.submission, retaining: prepared.retained, rtpTimestamp: pending.rtpTimestamp,
      receivedAt: pending.receivedAt, sourceTimestampNs: pending.sourceTimestampNs, isNewFrame: pending.isNewFrame,
      submittedAt: CACurrentMediaTime(), auditIdentity: pending.auditIdentity)
  }

  private func submit(
    _ submission: any ScreenSharingRenderSubmission, retaining retained: AnyObject & Sendable,
    rtpTimestamp: UInt32, receivedAt: Double?, sourceTimestampNs: Int64?, isNewFrame: Bool, submittedAt: Double,
    auditIdentity: ScreenSharingFrameDeliveryAudit.Identity? = nil
  ) {
    let metrics = metrics
    let hop = hop
    let renderOnArrival = renderOnArrival
    let mine = occupancy
    let startedNs = ScreenSharingMetrics.nowNs
    let audit = audit
    if isNewFrame, let receivedAt {
      metrics.observe("receiverCallbackToSubmission", milliseconds: (submittedAt - receivedAt) * 1000)
    }
    if let audit, isNewFrame { audit.record(.submission, auditIdentity, rtpTimestamp: rtpTimestamp) }
    submission.onCompleted { [weak self, retained, audit, auditIdentity] completed in
      withExtendedLifetime(retained) {}
      if let audit, isNewFrame {
        audit.record(.gpuCompletionCallback, auditIdentity, rtpTimestamp: rtpTimestamp, valueNs: completed ? 1 : 0)
      }
      if completed {
        if isNewFrame { metrics.increment("renderedFrames") }
        metrics.observe(
          "gpuSubmissionToCompletion", milliseconds: Double(ScreenSharingMetrics.nowNs - startedNs) / 1_000_000)
      } else {
        metrics.increment("renderErrors")
      }
      hop {
        guard let self, self.occupancy == mine, self.inFlight else { return }
        self.inFlight = false
        guard !self.stopped, renderOnArrival else { return }
        self.requestDraw()
      }
    }
    submission.onPresented {
      [
        weak self, metrics, hop, isNewFrame, submittedAt, receivedAt, sourceTimestampNs, rtpTimestamp, audit,
        auditIdentity
      ]
      presentedTime in
      if let audit, isNewFrame {
        audit.record(
          .presentedResult, auditIdentity, rtpTimestamp: rtpTimestamp,
          valueNs: presentedTime.isFinite && presentedTime > 0 ? Int64(presentedTime * 1_000_000_000) : 0)
      }
      let timed = metrics.recordPresentation(
        isNewFrame: isNewFrame, presentedAt: presentedTime, submittedAt: submittedAt, receivedAt: receivedAt)
      guard isNewFrame else { return }
      hop {
        guard let self, !self.stopped else { return }
        self.onPresented?(rtpTimestamp)
        guard timed else { return }
        self.onFramePresented?(
          ScreenSharingPresentedFrame(
            presentedAtSeconds: presentedTime, submittedAtSeconds: submittedAt, receivedAtSeconds: receivedAt,
            sourceTimestampNs: sourceTimestampNs, rtpTimestamp: rtpTimestamp))
      }
    }
    submission.commit()
  }

  private func releaseSlot(occupancy mine: Int) {
    guard occupancy == mine, inFlight else { return }
    inFlight = false
    guard !stopped, renderOnArrival else { return }
    requestDraw()
  }

  package func stop() {
    guard !stopped else { return }
    stopped = true
    requestDraw = {}
    mailbox.onFrameAvailable(nil)
    mailbox.clear()
    lastFrame = nil
    needsRedraw = false
    onFrameSize = nil
    onPresented = nil
    onFramePresented = nil
    metrics.label("rendererStopped", "true")
  }
}

public struct ScreenSharingPresentedFrame: Equatable, Sendable {
  public let presentedAtSeconds: Double
  public let submittedAtSeconds: Double
  public let receivedAtSeconds: Double?
  public let sourceTimestampNs: Int64?
  public let rtpTimestamp: UInt32

  public init(
    presentedAtSeconds: Double, submittedAtSeconds: Double, receivedAtSeconds: Double?, sourceTimestampNs: Int64?,
    rtpTimestamp: UInt32
  ) {
    self.presentedAtSeconds = presentedAtSeconds
    self.submittedAtSeconds = submittedAtSeconds
    self.receivedAtSeconds = receivedAtSeconds
    self.sourceTimestampNs = sourceTimestampNs
    self.rtpTimestamp = rtpTimestamp
  }
}
