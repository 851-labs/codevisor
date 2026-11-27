import CoreGraphics
import Foundation
import QuartzCore

package protocol ScreenSharingRenderSubmission: Sendable {
  func onCompleted(_ handler: @escaping @Sendable (_ completed: Bool) -> Void)
  func onPresented(_ handler: @escaping @Sendable (_ presentedTime: Double, _ gpuEndTime: Double?) -> Void)
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
  package var newer: (@Sendable () -> ScreenSharingVideoFrame?)?
  package var discardNewer: (@Sendable () -> Void)?
}

package struct ScreenSharingPreparedSubmission: Sendable {
  package let submission: any ScreenSharingRenderSubmission
  package let retained: AnyObject & Sendable
  package let videoSize: CGSize
  package let replacement: ScreenSharingVideoFrame?
  package let drawableWaitNs: Int64
  package init(
    submission: any ScreenSharingRenderSubmission, retained: AnyObject & Sendable, videoSize: CGSize,
    replacement: ScreenSharingVideoFrame? = nil, drawableWaitNs: Int64 = 0
  ) {
    self.submission = submission
    self.retained = retained
    self.videoSize = videoSize
    self.replacement = replacement
    self.drawableWaitNs = drawableWaitNs
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
  package private(set) var inFlight = false
  package var preparationToken: Int? { pending?.token }
  private struct PendingPreparation {
    let token: Int
    let frame: SubmittedFrame
    let taken: ScreenSharingTakenFrame
  }
  private struct SubmittedFrame {
    let rtpTimestamp: UInt32
    let receivedAt: Double?
    let sourceTimestampNs: Int64?
    let isNewFrame: Bool

    init(_ frame: ScreenSharingVideoFrame, isNewFrame: Bool) {
      rtpTimestamp = frame.rtpTimestamp
      receivedAt = frame.receivedAtSeconds
      sourceTimestampNs = frame.sourceTimestampNs
      self.isNewFrame = isNewFrame
    }
  }
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
  private let clock: ScreenSharingRenderClock
  private var catchUp = ScreenSharingFrameCatchUp()
  private var heldFrame: ScreenSharingVideoFrame?
  private var catchUpFallbackScheduled = false
  package var refreshPeriodNs: Int64 {
    get { catchUp.periodNs }
    set { catchUp.periodNs = newValue }
  }

  package init(
    mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, renderOnArrival: Bool,
    redrawsOnDemand: Bool = false,
    hop: @escaping Hop = { work in Task { @MainActor in work() } },
    clock: ScreenSharingRenderClock = .system
  ) {
    self.mailbox = mailbox
    self.metrics = metrics
    self.renderOnArrival = renderOnArrival
    self.redrawsOnDemand = redrawsOnDemand
    self.hop = hop
    self.clock = clock
    mailbox.recordArrivals(with: clock.now)
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
    noteArrivals()
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
    noteArrivals()
    guard !holdsToCatchUp() else { return nil }
    let incoming = takeIncoming()
    guard let frame = incoming ?? (needsRedraw ? lastFrame : nil) else { return nil }
    lastFrame = frame
    needsRedraw = false
    let isNewFrame = incoming != nil || owedPresentation
    owedPresentation = false
    return (frame, isNewFrame)
  }

  private func takeIncoming() -> ScreenSharingVideoFrame? {
    let held = heldFrame
    heldFrame = nil
    guard let arrived = mailbox.take() else { return held }

    if held != nil { metrics.increment("renderHeldFramesSuperseded") }
    return arrived
  }

  private func holdsToCatchUp() -> Bool {
    guard let waitNs = catchUp.holds(atNs: clock.now()) else { return false }

    if let arrived = mailbox.take() {
      if heldFrame != nil { metrics.increment("renderHeldFramesSuperseded") }
      heldFrame = arrived
    }
    guard !catchUpFallbackScheduled else { return true }

    catchUpFallbackScheduled = true
    clock.after(waitNs) { [weak self] in self?.catchUpFallback() }
    return true
  }

  private func catchUpFallback() {
    catchUpFallbackScheduled = false
    catchUp.finish(atNs: clock.now())
    guard !stopped, heldFrame != nil || needsRedraw || owedPresentation else { return }

    metrics.increment("renderCatchUpFallbacks")
    requestDraw()
  }

  private func noteArrivals() {
    for arrivedNs in mailbox.takeArrivals() { catchUp.arrived(atNs: arrivedNs) }
  }

  private func noteCommit(waitedForDrawableNs waitedNs: Int64, newFrame: Bool) {
    noteArrivals()
    guard catchUp.committed(waitedNs: waitedNs, newFrame: newFrame, atNs: clock.now()) else { return }

    metrics.increment("renderCatchUps")
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
    isNewFrame: Bool, submittedAt: Double, drawableWaitNs: Int64 = 0
  ) -> Bool {
    guard !stopped, !inFlight else { return false }
    inFlight = true
    occupancy += 1
    noteCommit(waitedForDrawableNs: drawableWaitNs, newFrame: isNewFrame)
    submit(
      submission, retaining: retained, frame: SubmittedFrame(frame, isNewFrame: isNewFrame), submittedAt: submittedAt)
    return true
  }

  @discardableResult
  package func prepare(with preparer: any ScreenSharingRenderPreparer, geometry: ScreenSharingRenderGeometry) -> Bool {
    guard let (frame, isNewFrame) = select() else { return false }
    inFlight = true
    occupancy += 1
    let token = occupancy
    let taken = ScreenSharingTakenFrame()
    pending = .init(token: token, frame: SubmittedFrame(frame, isNewFrame: isNewFrame), taken: taken)
    let hop = hop
    let mailbox = mailbox
    var request = ScreenSharingPreparationRequest(
      frame: frame, isNewFrame: isNewFrame, geometry: geometry, queuedAtNs: ScreenSharingMetrics.nowNs)
    request.newer = { taken.take(from: mailbox) }
    request.discardNewer = { taken.discard() }
    preparer.prepare(request) { [weak self] prepared in
      hop { self?.finishPreparation(token: token, prepared) }
    }
    return true
  }

  package func finishPreparation(token: Int, _ prepared: ScreenSharingPreparedSubmission?) {
    guard let pending, pending.token == token, occupancy == token else { return }
    self.pending = nil
    guard !stopped else {
      inFlight = false
      return
    }
    guard let prepared else {
      metrics.increment("renderDrops")
      if let taken = pending.taken.frame { heldFrame = taken }
      releaseSlot(occupancy: token)
      if pending.frame.isNewFrame { deferPresentation() }
      return
    }
    reportSize(prepared.videoSize)
    guard !stopped else {
      inFlight = false
      return
    }
    if let replacement = prepared.replacement {
      lastFrame = replacement
    } else if let taken = pending.taken.frame {
      heldFrame = taken
    }
    let drawn = prepared.replacement.map { SubmittedFrame($0, isNewFrame: true) } ?? pending.frame
    noteCommit(waitedForDrawableNs: prepared.drawableWaitNs, newFrame: drawn.isNewFrame && prepared.replacement == nil)
    submit(prepared.submission, retaining: prepared.retained, frame: drawn, submittedAt: CACurrentMediaTime())
  }

  private func submit(
    _ submission: any ScreenSharingRenderSubmission, retaining retained: AnyObject & Sendable,
    frame: SubmittedFrame, submittedAt: Double
  ) {
    let isNewFrame = frame.isNewFrame
    let metrics = metrics
    let hop = hop
    let renderOnArrival = renderOnArrival
    let mine = occupancy
    let startedNs = ScreenSharingMetrics.nowNs
    if isNewFrame, let receivedAt = frame.receivedAt {
      metrics.observe("receiverCallbackToSubmission", milliseconds: (submittedAt - receivedAt) * 1000)
    }
    submission.onCompleted { [weak self, retained] completed in
      withExtendedLifetime(retained) {}
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
    let commitEntry =
      isNewFrame
      ? metrics.commits.record(
        ScreenSharingCommitRecord(
          committedNs: ScreenSharingMetrics.nowNs, rtpTimestamp: frame.rtpTimestamp,
          sourceTimestampNs: frame.sourceTimestampNs))
      : nil
    submission.onPresented { [weak self] presentedTime, gpuEndTime in
      if let commitEntry, presentedTime > 0 {
        metrics.commits.presented(commitEntry, atNs: Int64(presentedTime * 1_000_000_000))
      }
      metrics.recordPresentation(
        isNewFrame: isNewFrame, presentedAt: presentedTime, submittedAt: submittedAt, receivedAt: frame.receivedAt,
        sourceTimestampNs: frame.sourceTimestampNs, gpuCompletedAt: gpuEndTime)
      guard isNewFrame else { return }
      hop {
        guard let self, !self.stopped else { return }
        self.onPresented?(frame.rtpTimestamp)
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
    mailbox.recordArrivals(with: nil)
    mailbox.clear()
    lastFrame = nil
    heldFrame = nil
    needsRedraw = false
    onFrameSize = nil
    onPresented = nil
    metrics.label("rendererStopped", "true")
  }
}
