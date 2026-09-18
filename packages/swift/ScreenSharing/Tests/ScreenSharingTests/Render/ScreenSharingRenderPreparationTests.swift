import CoreVideo
import Foundation
import Testing

@testable import ScreenSharing

/// Off-main preparation through the same coordinator: one reserved slot, the
/// newest mailbox frame, main-actor callbacks, and stop/failure/stale release.
/// The preparer is a controlled gate; the hop is the explicit queue.
@MainActor
struct ScreenSharingRenderPreparationTests {
  /// Scalars of a request, kept as history; the full request (with its frame)
  /// is held only while the preparation is outstanding and released on finish.
  private struct RequestSummary: Equatable {
    let rtpTimestamp: UInt32
    let isNewFrame: Bool
    let geometry: ScreenSharingRenderGeometry
  }

  private final class ControlledPreparer: ScreenSharingRenderPreparer, @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding:
      [(request: ScreenSharingPreparationRequest, completion: @Sendable (ScreenSharingPreparedSubmission?) -> Void)] =
        []
    private var history: [RequestSummary] = []
    func prepare(
      _ request: ScreenSharingPreparationRequest,
      completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void
    ) {
      lock.withLock {
        history.append(
          .init(rtpTimestamp: request.frame.rtpTimestamp, isNewFrame: request.isNewFrame, geometry: request.geometry))
        outstanding.append((request, completion))
      }
    }
    var requestCount: Int { lock.withLock { history.count } }
    var last: RequestSummary? { lock.withLock { history.last } }
    var outstandingCount: Int { lock.withLock { outstanding.count } }
    /// Finishes the oldest outstanding preparation with a result built from its
    /// frame (or nil), then releases the request — the worker keeps nothing.
    func finish(_ make: (ScreenSharingVideoFrame) -> ScreenSharingPreparedSubmission?) {
      let entry = lock.withLock { outstanding.isEmpty ? nil : outstanding.removeFirst() }
      guard let entry else { return }
      let prepared = make(entry.request.frame)
      entry.completion(prepared)
    }
  }

  private final class ControlledSubmission: ScreenSharingRenderSubmission, @unchecked Sendable {
    private let lock = NSLock()
    private var completed: (@Sendable (Bool) -> Void)?
    private var presented: (@Sendable (Double) -> Void)?
    private var installedCompletion: (@Sendable (Bool) -> Void)?
    private(set) var committed = false
    func onCompleted(_ handler: @escaping @Sendable (Bool) -> Void) {
      lock.withLock {
        completed = handler
        installedCompletion = handler
      }
    }
    func onPresented(_ handler: @escaping @Sendable (Double) -> Void) { lock.withLock { presented = handler } }
    func commit() { lock.withLock { committed = true } }
    var holdsHandlers: Bool { lock.withLock { completed != nil || presented != nil } }
    var holdsPresentationHandler: Bool { lock.withLock { presented != nil } }
    func complete(_ success: Bool = true) {
      let handler = lock.withLock {
        let h = completed; completed = nil; return h
      }
      handler?(success)
    }
    func replayCompletion(_ success: Bool = true) -> Bool {
      guard let handler = lock.withLock({ installedCompletion }) else { return false }
      handler(success)
      return true
    }
    func forgetInstalledCompletion() { lock.withLock { installedCompletion = nil } }
    func present(at time: Double) {
      let handler = lock.withLock {
        let h = presented; presented = nil; return h
      }
      handler?(time)
    }
  }

  private final class WorkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [@Sendable @MainActor () -> Void] = []
    var hop: ScreenSharingRenderCoordinator.Hop { { [self] work in self.lock.withLock { self.items.append(work) } } }
    var pending: Int { lock.withLock { items.count } }
    @MainActor func drain() -> Int {
      let work = lock.withLock {
        let w = items; items = []; return w
      }
      for item in work { item() }
      return work.count
    }
  }

  private final class Retained: @unchecked Sendable {
    let frame: ScreenSharingVideoFrame
    init(_ frame: ScreenSharingVideoFrame) { self.frame = frame }
  }

  @MainActor private struct Fixture {
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    let queue = WorkQueue()
    let preparer = ControlledPreparer()
    let coordinator: ScreenSharingRenderCoordinator
    let draws = Counter()
    @MainActor final class Counter { var value = 0 }
    static let size = CGSize(width: 1920, height: 1080)
    let geometry = ScreenSharingRenderGeometry(
      clearColor: SIMD4(0.1, 0.2, 0.3, 1), drawableSize: size)
    init() {
      coordinator = ScreenSharingRenderCoordinator(
        mailbox: mailbox, metrics: metrics, renderOnArrival: true, redrawsOnDemand: true, hop: queue.hop)
      let draws = draws
      coordinator.bind { draws.value += 1 }
    }
    func counter(_ name: String) -> Int { metrics.snapshot().counters[name] ?? 0 }
    /// What the view does on a draw request in the off-main mode (size from its backing store).
    @discardableResult func drawRequested(size: CGSize = size) -> Bool {
      coordinator.prepare(
        with: preparer,
        geometry: .init(clearColor: geometry.clearColor, drawableSize: size))
    }
    /// A prepared result: the submission plus the retained frame (as the worker's TextureFrame would be).
    func prepared(_ submission: ControlledSubmission) -> (ScreenSharingVideoFrame) -> ScreenSharingPreparedSubmission? {
      { frame in .init(submission: submission, retained: Retained(frame), videoSize: CGSize(width: 64, height: 64)) }
    }
  }

  private func makeBuffer() throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return try #require(pixel)
  }

  private func frame(_ buffer: CVPixelBuffer, rtp: UInt32 = 7, receivedAt: Double? = 1.0) -> ScreenSharingVideoFrame {
    .init(pixelBuffer: buffer, timestampNs: Int64(rtp), rtpTimestamp: rtp, receivedAtSeconds: receivedAt)
  }

  @Test func oneSlotNewestMailboxFrameAndMainActorCallbacks() throws {
    let f = Fixture()
    var sizes: [CGSize] = []
    var notified: [UInt32] = []
    f.coordinator.onFrameSize = { sizes.append($0) }
    f.coordinator.onPresented = { notified.append($0) }
    f.mailbox.put(frame(try makeBuffer(), rtp: 1))
    #expect(f.queue.drain() == 1 && f.draws.value == 1)
    #expect(f.drawRequested())
    let request = try #require(f.preparer.last)
    #expect(request.isNewFrame && request.rtpTimestamp == 1 && request.geometry == f.geometry)
    #expect(request.geometry.drawableSize == Fixture.size)  // the size travels with the request
    #expect(f.coordinator.inFlight && f.coordinator.preparationToken != nil && f.coordinator.isHoldingCachedFrame)
    // While the slot is held: a second draw request prepares nothing, commits are refused,
    // arrivals only replace the mailbox's newest frame.
    #expect(!f.drawRequested() && f.preparer.requestCount == 1)
    let refused = ControlledSubmission()
    let held = frame(try makeBuffer(), rtp: 99)
    #expect(!f.coordinator.commit(refused, retaining: Retained(held), frame: held, isNewFrame: true, submittedAt: 1))
    f.mailbox.put(frame(try makeBuffer(), rtp: 2))
    f.mailbox.put(frame(try makeBuffer(), rtp: 3))
    _ = f.queue.drain()  // the arrival hop for frame 2 requests a draw, which prepares nothing
    #expect(f.preparer.requestCount == 1 && f.mailbox.isHolding && f.mailbox.droppedFrames == 1)
    // The worker finishes; the result is committed on the main actor behind the guard.
    let submission = ControlledSubmission()
    f.preparer.finish(f.prepared(submission))
    #expect(f.queue.drain() == 1)
    #expect(submission.committed && f.coordinator.inFlight && f.coordinator.preparationToken == nil)
    #expect(sizes == [CGSize(width: 64, height: 64)])
    submission.present(at: 2)
    _ = f.queue.drain()
    #expect(notified == [1])
    // GPU completion — not presentation — releases the slot and drives the next arrival.
    submission.complete()
    _ = f.queue.drain()
    #expect(!f.coordinator.inFlight && f.counter("renderedFrames") == 1)
    #expect(f.drawRequested() && f.preparer.last?.rtpTimestamp == 3)  // newest, frame 2 was replaced
  }

  @Test func stopWhilePreparationIsHeldClearsTheSlotOnTheLateResultAndReleasesEverything() throws {
    let f = Fixture()
    var sizes: [CGSize] = []
    f.coordinator.onFrameSize = { sizes.append($0) }
    weak var weakBuffer: CVPixelBuffer?
    let submission = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      f.mailbox.put(frame(buffer))
      _ = f.queue.drain()
      #expect(f.drawRequested())
    }
    #expect(weakBuffer != nil && f.preparer.outstandingCount == 1)  // held by the cache and the outstanding request
    f.coordinator.stop()
    // the executing preparation is still accounted
    #expect(f.coordinator.inFlight && f.coordinator.preparationToken != nil)
    #expect(!f.coordinator.isHoldingCachedFrame && weakBuffer != nil)  // only the worker's request holds it now
    autoreleasepool { f.preparer.finish(f.prepared(submission)) }  // the worker returns once; its request is released
    #expect(f.queue.drain() == 1)
    #expect(!f.coordinator.inFlight && f.coordinator.preparationToken == nil)  // slot gone
    #expect(!submission.committed && !submission.holdsHandlers && sizes.isEmpty && f.draws.value == 1)
    #expect(weakBuffer == nil)  // the dropped result retained nothing
    #expect(f.counter("renderedFrames") == 0 && f.counter("renderDrops") == 0)
    #expect(f.queue.pending == 0)
  }

  @Test func committedResultKeepsResourcesThroughStopUntilGPUCompletionWhilePresentationHoldsScalarsOnly() throws {
    let f = Fixture()
    var notified: [UInt32] = []
    f.coordinator.onPresented = { notified.append($0) }
    weak var weakBuffer: CVPixelBuffer?
    let submission = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      f.mailbox.put(frame(buffer, rtp: 5))
      _ = f.queue.drain()
      #expect(f.drawRequested())
      f.preparer.finish(f.prepared(submission))
      _ = f.queue.drain()
    }
    #expect(submission.committed && f.coordinator.inFlight)
    f.coordinator.stop()
    #expect(f.coordinator.inFlight && weakBuffer != nil)  // GPU still owns the buffer and textures
    submission.complete()
    submission.forgetInstalledCompletion()
    _ = f.queue.drain()
    #expect(!f.coordinator.inFlight && f.draws.value == 1)  // slot cleared, no restart after stop
    // released; the pending presentation handler holds scalars only
    #expect(weakBuffer == nil && submission.holdsPresentationHandler)
    submission.present(at: 3)
    _ = f.queue.drain()
    #expect(notified.isEmpty && f.counter("presentationCallbacks") == 1)
  }

  @Test func preparationFailureReleasesTheSlotAndItsRequestAndDrivesTheWaitingFrame() throws {
    let f = Fixture()
    weak var weakFirst: CVPixelBuffer?
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakFirst = buffer
      f.mailbox.put(frame(buffer, rtp: 1))
      _ = f.queue.drain()
      #expect(f.drawRequested())
      f.mailbox.put(frame(try makeBuffer(), rtp: 2))
      _ = f.queue.drain()  // arrival while held: no preparation
      #expect(f.preparer.requestCount == 1)
      f.preparer.finish { _ in nil }  // e.g. no drawable (timeout or invalid layer properties)
    }
    #expect(f.queue.drain() == 1)
    #expect(!f.coordinator.inFlight && f.counter("renderDrops") == 1 && f.draws.value == 3)
    #expect(f.drawRequested() && f.preparer.last?.rtpTimestamp == 2)  // the waiting newest frame proceeds
    #expect(weakFirst == nil)  // frame 1: request released on failure, cache replaced by frame 2
  }

  @Test func idleCachedFrameRedrawsOnResizeOrFitWithoutANewVideoFrame() throws {
    let f = Fixture()
    f.mailbox.put(frame(try makeBuffer(), rtp: 1))
    _ = f.queue.drain()
    #expect(f.drawRequested())
    let submission = ControlledSubmission()
    f.preparer.finish(f.prepared(submission))
    _ = f.queue.drain()
    submission.complete()
    _ = f.queue.drain()
    #expect(!f.coordinator.inFlight && !f.mailbox.isHolding)  // idle, cache held, no video frame coming
    let drawsBefore = f.draws.value
    f.coordinator.setNeedsRedraw()  // resize / backing scale / fit change
    f.coordinator.setNeedsRedraw()  // coalesced: one scheduled hop for the burst
    #expect(f.draws.value == drawsBefore && f.queue.pending == 1)  // never a synchronous reentrant draw
    #expect(f.queue.drain() == 1 && f.draws.value == drawsBefore + 1)
    #expect(f.drawRequested(size: CGSize(width: 1280, height: 720)))
    let redraw = try #require(f.preparer.last)
    #expect(!redraw.isNewFrame && redraw.rtpTimestamp == 1)
    #expect(redraw.geometry.drawableSize == CGSize(width: 1280, height: 720))
    // A redraw requested while the slot is held waits for completion (no extra draw).
    f.coordinator.setNeedsRedraw()
    #expect(f.queue.drain() == 1 && f.draws.value == drawsBefore + 1)
    let second = ControlledSubmission()
    f.preparer.finish(f.prepared(second))
    _ = f.queue.drain()
    second.complete()
    _ = f.queue.drain()
    // completion drove the pending redraw
    #expect(f.draws.value == drawsBefore + 2 && f.coordinator.select()?.isNewFrame == false)
  }

  @Test func sizeCallbackStoppingTheRendererDropsThePreparedResultAndClearsTheSlot() throws {
    let f = Fixture()
    let coordinator = f.coordinator
    coordinator.onFrameSize = { _ in coordinator.stop() }
    weak var weakBuffer: CVPixelBuffer?
    let submission = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      f.mailbox.put(frame(buffer))
      _ = f.queue.drain()
      #expect(f.drawRequested())
      f.preparer.finish(f.prepared(submission))
      _ = f.queue.drain()
    }
    #expect(coordinator.stopped && !submission.committed && !submission.holdsHandlers)
    #expect(!coordinator.inFlight && coordinator.preparationToken == nil)  // prepared-but-unsubmitted slot released
    #expect(weakBuffer == nil)
  }

  @Test func staleResultsAndReplayedOldCompletionsNeverScheduleOrReleaseAnotherOccupancy() throws {
    let f = Fixture()
    f.mailbox.put(frame(try makeBuffer(), rtp: 1))
    _ = f.queue.drain()
    #expect(f.drawRequested())
    let firstSubmission = ControlledSubmission()
    f.preparer.finish(f.prepared(firstSubmission))
    _ = f.queue.drain()
    firstSubmission.complete()
    _ = f.queue.drain()
    #expect(!f.coordinator.inFlight)
    // A second occupancy is reserved; then the FIRST submission's completion fires again (replayed).
    f.mailbox.put(frame(try makeBuffer(), rtp: 2))
    _ = f.queue.drain()
    #expect(f.drawRequested() && f.coordinator.inFlight)
    let drawsBefore = f.draws.value
    #expect(firstSubmission.replayCompletion())
    #expect(f.queue.drain() == 1)
    #expect(f.coordinator.inFlight && f.coordinator.preparationToken != nil && f.draws.value == drawsBefore)
    // A stale result for the first token is ignored while the second preparation is held.
    let stale = ControlledSubmission()
    let staleFrame = frame(try makeBuffer(), rtp: 1)
    f.coordinator.finishPreparation(
      token: 1, .init(submission: stale, retained: Retained(staleFrame), videoSize: .zero))
    #expect(!stale.committed && f.coordinator.inFlight && f.coordinator.preparationToken != nil)
    // The second result commits; a duplicate result for the same token is ignored.
    let secondSubmission = ControlledSubmission()
    f.preparer.finish(f.prepared(secondSubmission))
    _ = f.queue.drain()
    #expect(secondSubmission.committed)
    let duplicate = ControlledSubmission()
    f.coordinator.finishPreparation(
      token: 2, .init(submission: duplicate, retained: Retained(staleFrame), videoSize: .zero))
    #expect(!duplicate.committed && f.coordinator.inFlight)
    secondSubmission.complete()
    _ = f.queue.drain()
    #expect(!f.coordinator.inFlight)
  }
}
