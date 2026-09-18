import CoreGraphics
import Foundation
import QuartzCore

/// The GPU/compositor side of one render submission. The real adapter wraps an
/// `MTLCommandBuffer` and its `CAMetalDrawable`; tests supply a controlled one.
/// Handlers are installed before `commit()`; each is invoked at most once, on
/// any thread.
package protocol ScreenSharingRenderSubmission: Sendable {
  /// Invoked when the GPU work finished (`completed` = status `.completed`).
  func onCompleted(_ handler: @escaping @Sendable (_ completed: Bool) -> Void)
  /// Invoked when the drawable is presented, or resolved unpresented (`presentedTime` 0).
  func onPresented(_ handler: @escaping @Sendable (_ presentedTime: Double) -> Void)
  func commit()
}

/// Immutable main-actor values a worker needs to size the layer and encode a
/// frame; never AppKit. `drawableSize` is the view's backing size at request
/// time: the worker applies it to the layer right before acquiring, so layer
/// sizing and acquisition are serialized on the worker without any lock the
/// main actor could wait on.
package struct ScreenSharingRenderGeometry: Equatable, Sendable {
  package let clearColor: SIMD4<Double>
  package let drawableSize: CGSize
  package init(clearColor: SIMD4<Double>, drawableSize: CGSize) {
    self.clearColor = clearColor
    self.drawableSize = drawableSize
  }
}

/// One off-main preparation: the selected frame plus its geometry snapshot.
package struct ScreenSharingPreparationRequest: Sendable {
  package let frame: ScreenSharingVideoFrame
  package let isNewFrame: Bool
  package let geometry: ScreenSharingRenderGeometry
  /// When the main actor queued the request (worker queue-wait telemetry only).
  package let queuedAtNs: Int64
  /// Receiver-only diagnostic identity (nil when the audit is off or the frame carried none).
  package let auditIdentity: ScreenSharingFrameDeliveryAudit.Identity?
}

/// A prepared (acquired + encoded, not committed) submission returned to the
/// main actor. `retained` is the pixel buffer with its Metal textures.
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

/// Diagnostic off-main preparation: acquires a drawable and encodes on its own
/// serial worker, then hands the result back exactly once. The real preparer
/// uses `CAMetalLayer.nextDrawable`; tests supply a controlled one.
package protocol ScreenSharingRenderPreparer: Sendable {
  func prepare(
    _ request: ScreenSharingPreparationRequest,
    completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void)
}

/// Main-actor scheduling and ownership state of the Metal renderer, used by
/// `ScreenSharingMetalView` for every draw. Frame selection, completion pacing
/// and the retained-until-completion rule are unchanged; `stop()` is the one
/// terminal boundary after which nothing is scheduled, cached, submitted or notified.
@MainActor
package final class ScreenSharingRenderCoordinator {
  package typealias Hop = @Sendable (_ work: @escaping @Sendable @MainActor () -> Void) -> Void

  package let mailbox: ScreenSharingFrameMailbox
  package let metrics: ScreenSharingMetrics
  package let renderOnArrival: Bool
  /// Reported once per video size change; cleared by `stop()`.
  package var onFrameSize: ((CGSize) -> Void)? {
    didSet { if stopped { onFrameSize = nil } }
  }
  /// Product presentation notification; cleared by `stop()`.
  package var onPresented: ((UInt32) -> Void)? {
    didSet { if stopped { onPresented = nil } }
  }
  /// Diagnostic presentation notification with the frame's identity and clocks; nil (no work) unless a
  /// tool sets it. Cleared by `stop()`.
  package var onFramePresented: ((ScreenSharingPresentedFrame) -> Void)? {
    didSet { if stopped { onFramePresented = nil } }
  }
  /// The single slot: true while a frame is being prepared or its submission is in flight.
  package private(set) var inFlight = false
  /// Set while the slot is held by an off-main preparation (nil otherwise).
  package var preparationToken: Int? { pending?.token }
  private struct PendingPreparation {
    let token: Int
    let rtpTimestamp: UInt32
    let receivedAt: Double?
    let sourceTimestampNs: Int64?
    let isNewFrame: Bool
    let auditIdentity: ScreenSharingFrameDeliveryAudit.Identity?
  }
  /// Receiver-only diagnostic frame-delivery audit (nil = disabled: every hook is one nil branch).
  package var audit: ScreenSharingFrameDeliveryAudit?
  /// Scalars of the frame being prepared, kept here so the worker never has
  /// to echo them back. Survives `stop()`: the executing preparation still
  /// returns once, and that return clears the slot.
  private var pending: PendingPreparation?
  /// Off-main mode: a redraw request (resize, backing scale) schedules a
  /// draw through the hop when the renderer is idle, instead of waiting for
  /// the next video frame. Never synchronous from the caller.
  private let redrawsOnDemand: Bool
  /// One scheduled redraw hop at a time: a burst of resize changes
  /// coalesces into a single draw request.
  private var redrawHopPending = false
  package private(set) var stopped = false
  /// Ownership observation only: the cached redraw frame is held.
  package var isHoldingCachedFrame: Bool { lastFrame != nil }
  private var lastFrame: ScreenSharingVideoFrame?
  private var needsRedraw = false
  /// A new frame was selected but could not be drawn (no drawable yet, encoding refused): the next
  /// draw of the cached frame still owes the product its presentation. Without this a one-shot
  /// source — a VNC desktop that only repaints on change — renders on a later redraw but never
  /// reports ready.
  private var owedPresentation = false
  private var reportedSize = CGSize.zero
  private var requestDraw: @MainActor () -> Void = {}
  private let hop: Hop
  /// Incremented whenever the slot is taken; a completion or preparation
  /// result only counts for the occupancy it was created under.
  private var occupancy = 0

  /// `hop` moves queued work (arrival, completion, presentation, prepared
  /// results) onto the main actor; the default is a Task. Tests supply a
  /// controlled queue.
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

  /// Installs the view's draw request and, for the arrival scheduler,
  /// subscribes to frame arrival (a frame already waiting is scheduled at once,
  /// mailbox semantics). Ignored once stopped.
  package func bind(requestDraw: @escaping @MainActor () -> Void) {
    guard !stopped else { return }
    self.requestDraw = requestDraw
    guard renderOnArrival else { return }
    let hop = hop
    mailbox.onFrameAvailable { [weak self] in hop { self?.arrivalScheduled() } }
  }

  /// Main-actor entry of a queued arrival notification.
  package func arrivalScheduled() {
    guard !stopped else { return }
    requestDraw()
  }

  /// A resize asks for one redraw of the cached frame. With
  /// `redrawsOnDemand` the draw is scheduled through the hop (coalesced by the
  /// flag: later hops find nothing to do); never a synchronous reentrant draw.
  package func setNeedsRedraw() {
    guard !stopped else { return }
    needsRedraw = true
    guard redrawsOnDemand, !redrawHopPending else { return }
    redrawHopPending = true
    let hop = hop
    hop { [weak self] in self?.redrawScheduled() }
  }

  /// Main-actor entry of a scheduled redraw: draws only when idle and still
  /// needed (a redraw needed while the slot is held is picked up by the
  /// completion-driven draw request).
  package func redrawScheduled() {
    redrawHopPending = false
    guard !stopped, needsRedraw, !inFlight else { return }
    requestDraw()
  }

  /// Frame selection, unchanged: nothing while stopped or while the slot is
  /// held; the incoming frame first, else the cached frame for a redraw. The
  /// selected frame becomes the cached frame before encoding, as before.
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

  /// The frame `select()` just returned as new was dropped before submission.
  /// Its presentation is owed: the cached frame is redrawn and that draw
  /// counts as new. Nothing after `stop()`.
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

  /// Main-actor path: installs the completion and presentation handlers and
  /// commits an already encoded submission. `retained` (the pixel buffer and
  /// its Metal textures) is held by the completion handler until the GPU
  /// actually finished — also after `stop()`. The presentation handler
  /// captures only the scalars it reports. Refused (false, nothing installed,
  /// nothing retained, nothing submitted) once stopped — a callback between
  /// `select()` and here may have stopped the renderer — or while the slot is
  /// held by another submission or preparation.
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

  /// Off-main diagnostic path: selects with the unchanged ordering, reserves
  /// the single slot, snapshots the geometry and hands the frame to the
  /// preparer. Exactly one preparation or submission is outstanding; a frame
  /// arriving meanwhile only replaces the mailbox's newest frame. Returns
  /// false when nothing was selected or the slot is held.
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

  /// Main-actor entry of a preparation result. Stale results (another
  /// occupancy, or a token already consumed) are ignored. The held slot is
  /// always cleared by the actual return of its preparation: after `stop()`
  /// the result is dropped uncommitted and the slot cleared without
  /// rescheduling; a failed preparation releases the slot; the size callback
  /// may stop the renderer, in which case the prepared result is dropped and
  /// the slot cleared as well; otherwise the prepared submission is committed.
  package func finishPreparation(token: Int, _ prepared: ScreenSharingPreparedSubmission?) {
    guard let pending, pending.token == token, occupancy == token else { return }
    self.pending = nil
    if let audit {
      audit.record(
        .preparedReceipt, pending.auditIdentity, rtpTimestamp: pending.rtpTimestamp, valueNs: prepared == nil ? 0 : 1)
    }
    guard !stopped else {
      inFlight = false  // the worker's result is dropped here; nothing else will clear the slot
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
      inFlight = false  // prepared but never submitted: no GPU completion will clear it
      return
    }
    submit(
      prepared.submission, retaining: prepared.retained, rtpTimestamp: pending.rtpTimestamp,
      receivedAt: pending.receivedAt, sourceTimestampNs: pending.sourceTimestampNs, isNewFrame: pending.isNewFrame,
      submittedAt: CACurrentMediaTime(), auditIdentity: pending.auditIdentity)
  }

  /// Final submission boundary for both paths: `gpuSubmissionToCompletion`
  /// starts here (never during acquisition or preparation), and
  /// `receiverCallbackToSubmission` is observed exactly once per new frame.
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
      // The handler itself is the product signal: the drawable of a new frame
      // reached Core Animation. Its `presentedTime` is a diagnostic — it reads
      // 0 for a sparsely presented layer (a VNC desktop that repaints on
      // change) although the frame is on screen — so only the latency
      // metrics and the diagnostic notification depend on it.
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

  /// Terminal and idempotent. Releases immediately: the draw request, the
  /// arrival subscription, the mailbox frame, the cached redraw frame, the
  /// pending redraw and both product callbacks. Not released here: a
  /// submission in flight keeps its buffer and textures until its own
  /// completion handler runs (that handler then only clears the slot); a
  /// preparation already executing on its worker finishes or fails on its
  /// own, cannot touch AppKit, and its one return clears the slot here with
  /// the result dropped uncommitted (the reservation identity is kept for
  /// that). Nothing joins WebRTC, VideoToolbox, GPU or worker threads.
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

/// One on-screen presentation as seen by the renderer: receiver-local Core Animation clock values plus the
/// frame's in-band content identity (the host's capture timestamp). Comparing the two clocks needs a
/// calibrated offset; the library never does that itself.
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
