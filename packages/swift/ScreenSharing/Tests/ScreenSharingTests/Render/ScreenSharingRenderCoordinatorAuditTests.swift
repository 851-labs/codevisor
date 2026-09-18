import CoreVideo
import Foundation
import Testing

@testable import ScreenSharing

/// Audit boundaries through the real coordinator seams (main-actor commit and
/// off-main preparation): identity carried as scalars from the selected frame
/// to submission, GPU completion callback and presented result; nil audit = no
/// recording and no clock reads.
@MainActor
struct ScreenSharingRenderCoordinatorAuditTests {
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reads = 0
    var read: @Sendable () -> Int64 {
      { [self] in
        self.lock.withLock {
          self.reads += 1; return 1_500_000_000
        }
      }
    }
  }
  private final class ControlledSubmission: ScreenSharingRenderSubmission, @unchecked Sendable {
    private let lock = NSLock()
    private var completed: (@Sendable (Bool) -> Void)?
    private var presented: (@Sendable (Double) -> Void)?
    func onCompleted(_ handler: @escaping @Sendable (Bool) -> Void) { lock.withLock { completed = handler } }
    func onPresented(_ handler: @escaping @Sendable (Double) -> Void) { lock.withLock { presented = handler } }
    func commit() {}
    func complete(_ ok: Bool) {
      lock.withLock {
        let h = completed; completed = nil; return h
      }?(ok)
    }
    func present(at t: Double) {
      lock.withLock {
        let h = presented; presented = nil; return h
      }?(t)
    }
  }
  private final class Retained: @unchecked Sendable {
    let frame: ScreenSharingVideoFrame
    init(_ frame: ScreenSharingVideoFrame) { self.frame = frame }
  }
  private final class ControlledPreparer: ScreenSharingRenderPreparer, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(ScreenSharingPreparationRequest, @Sendable (ScreenSharingPreparedSubmission?) -> Void)] = []
    func prepare(
      _ request: ScreenSharingPreparationRequest,
      completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void
    ) {
      lock.withLock { pending.append((request, completion)) }
    }
    var lastIdentity: ScreenSharingFrameDeliveryAudit.Identity?? {
      lock.withLock { pending.last.map { $0.0.auditIdentity } }
    }
    func finish(_ make: (ScreenSharingVideoFrame) -> ScreenSharingPreparedSubmission?) {
      let entry = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
      guard let entry else { return }
      entry.1(make(entry.0.frame))
    }
  }

  private func makeBuffer() throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return try #require(pixel)
  }

  @Test func mainActorPathRecordsSelectionSubmissionCompletionAndPresentedWithTheFrameIdentity() throws {
    let clock = Clock()
    let audit = ScreenSharingFrameDeliveryAudit(
      window: try .init(beginSeconds: 0, durationSeconds: 10), clock: clock.read)
    audit.start(originNs: 0)
    let mailbox = ScreenSharingFrameMailbox()
    let coordinator = ScreenSharingRenderCoordinator(
      mailbox: mailbox, metrics: ScreenSharingMetrics(), renderOnArrival: false,
      hop: { work in MainActor.assumeIsolated { work() } })
    coordinator.bind {}
    coordinator.audit = audit
    let identity = ScreenSharingFrameDeliveryAudit.Identity(sequence: 42, generation: 1)
    weak var weakBuffer: CVPixelBuffer?
    let submission = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      mailbox.put(
        .init(
          pixelBuffer: buffer, timestampNs: 1, rtpTimestamp: 900, receivedAtSeconds: 1.0,
          deliveryAuditIdentity: identity))
      let selected = try #require(coordinator.select())
      #expect(
        coordinator.commit(
          submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1.2))
      coordinator.setNeedsRedraw()
    }
    submission.present(at: 1.25)
    submission.complete(true)
    let s = audit.snapshot()
    #expect(s.stages == [4, 9, 11, 10] && s.sequences == [42, 42, 42, 42] && s.rtpTimestamps == [900, 900, 900, 900])
    #expect(s.valueNs == [0, 0, 1_250_000_000, 1] && s.duplicateEvents == 0 && s.missingIdentityEvents == 0)
    // a cached redraw is not a delivery: selecting the cache records nothing
    #expect(coordinator.select()?.isNewFrame == false && audit.snapshot().recorded == 4)
    #expect(weakBuffer != nil)  // only the coordinator's redraw cache still holds the buffer …
    coordinator.stop()
    #expect(weakBuffer == nil && audit.snapshot().recorded == 4)  // … the audit's four records retained nothing
  }

  @Test func preparationPathCarriesTheIdentityToPreparedReceiptSubmissionAndCompletion() throws {
    let clock = Clock()
    let audit = ScreenSharingFrameDeliveryAudit(
      window: try .init(beginSeconds: 0, durationSeconds: 10), clock: clock.read)
    audit.start(originNs: 0)
    let mailbox = ScreenSharingFrameMailbox()
    let coordinator = ScreenSharingRenderCoordinator(
      mailbox: mailbox, metrics: ScreenSharingMetrics(), renderOnArrival: true, redrawsOnDemand: true,
      hop: { work in MainActor.assumeIsolated { work() } })
    coordinator.bind {}
    coordinator.audit = audit
    let preparer = ControlledPreparer()
    let identity = ScreenSharingFrameDeliveryAudit.Identity(sequence: 7, generation: 2)
    mailbox.put(
      .init(
        pixelBuffer: try makeBuffer(), timestampNs: 1, rtpTimestamp: 70, receivedAtSeconds: 1.0,
        deliveryAuditIdentity: identity))
    #expect(
      coordinator.prepare(
        with: preparer, geometry: .init(clearColor: .zero, drawableSize: CGSize(width: 8, height: 8))
      ))
    #expect(preparer.lastIdentity == .some(identity))  // the worker request carries the identity as a scalar
    let submission = ControlledSubmission()
    preparer.finish { frame in
      .init(submission: submission, retained: Retained(frame), videoSize: CGSize(width: 16, height: 16))
    }
    submission.complete(true)
    submission.present(at: 0)  // unpresented result must be declared, not skipped
    let s = audit.snapshot()
    #expect(s.stages == [4, 8, 9, 10, 11] && s.sequences.allSatisfy { $0 == 7 } && s.valueNs == [0, 1, 0, 1, 0])
    #expect(s.coverage["presentedResultZero"] == 1)
    // a failed preparation is still receipted (value 0) and nothing else is recorded for it
    mailbox.put(
      .init(
        pixelBuffer: try makeBuffer(), timestampNs: 2, rtpTimestamp: 71, receivedAtSeconds: 1.1,
        deliveryAuditIdentity: .init(sequence: 8, generation: 2)))
    #expect(
      coordinator.prepare(
        with: preparer, geometry: .init(clearColor: .zero, drawableSize: CGSize(width: 8, height: 8))
      ))
    preparer.finish { _ in nil }
    let t = audit.snapshot()
    #expect(t.stages.suffix(2) == [4, 8] && t.valueNs.last == 0 && t.sequences.suffix(2) == [8, 8])
  }

  @Test func nilAuditRecordsNothingAndReadsNoClock() throws {
    let clock = Clock()
    let audit = ScreenSharingFrameDeliveryAudit(
      window: try .init(beginSeconds: 0, durationSeconds: 10), clock: clock.read)
    let mailbox = ScreenSharingFrameMailbox()
    let coordinator = ScreenSharingRenderCoordinator(
      mailbox: mailbox, metrics: ScreenSharingMetrics(), renderOnArrival: false,
      hop: { work in MainActor.assumeIsolated { work() } })
    coordinator.bind {}
    #expect(coordinator.audit == nil)  // default: disabled
    mailbox.put(.init(pixelBuffer: try makeBuffer(), timestampNs: 1, rtpTimestamp: 5, receivedAtSeconds: 1.0))
    let selected = try #require(coordinator.select())
    let submission = ControlledSubmission()
    #expect(
      coordinator.commit(
        submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1.2))
    submission.present(at: 1.3)
    submission.complete(true)
    #expect(clock.reads == 0 && audit.snapshot().recorded == 0 && selected.frame.deliveryAuditIdentity == nil)
  }
}
