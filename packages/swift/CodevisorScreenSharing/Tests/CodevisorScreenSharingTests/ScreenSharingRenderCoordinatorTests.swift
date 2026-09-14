import CoreVideo
import Foundation
import Testing

@testable import CodevisorScreenSharing

/// Lifecycle and ownership of the renderer's scheduling state through the
/// real coordinator used by `ScreenSharingMetalView`, with a controlled
/// submission (completion/presentation delivered by the test) and a controlled
/// hop (queued main-actor work drained by the test). No Metal, no window.
@MainActor
struct ScreenSharingRenderCoordinatorTests {
  /// Records the installed handlers; the test decides when the GPU "completes"
  /// and when the drawable is "presented".
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

  /// Queued main-actor work (arrival, completion, presentation hops), drained explicitly.
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

  /// Stand-in for the view's retained textures + frame (released at GPU completion).
  private final class Retained: @unchecked Sendable {
    let frame: ScreenSharingVideoFrame
    init(_ frame: ScreenSharingVideoFrame) { self.frame = frame }
  }

  @MainActor private struct Fixture {
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    let queue = WorkQueue()
    let coordinator: ScreenSharingRenderCoordinator
    let draws = Counter()
    @MainActor final class Counter { var value = 0 }
    init(renderOnArrival: Bool) {
      coordinator = ScreenSharingRenderCoordinator(
        mailbox: mailbox, metrics: metrics, renderOnArrival: renderOnArrival, hop: queue.hop)
      let draws = draws
      coordinator.bind { draws.value += 1 }
    }
    func counter(_ name: String) -> Int { metrics.snapshot().counters[name] ?? 0 }
  }

  private func makeBuffer() throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return try #require(pixel)
  }

  private func frame(_ buffer: CVPixelBuffer, rtp: UInt32 = 7, receivedAt: Double? = 1.0) -> ScreenSharingVideoFrame {
    .init(pixelBuffer: buffer, timestampNs: Int64(rtp), rtpTimestamp: rtp, receivedAtSeconds: receivedAt)
  }

  /// Selection order is unchanged: nothing in flight → incoming first; the
  /// incoming frame is cached; a redraw re-selects the cache as not-new; while
  /// in flight nothing is taken and the mailbox keeps its frame.
  @Test func selectionOrderAndCachingAreUnchanged() throws {
    let f = Fixture(renderOnArrival: false)
    #expect(f.coordinator.select() == nil)
    f.mailbox.put(frame(try makeBuffer(), rtp: 1))
    let first = try #require(f.coordinator.select())
    #expect(first.isNewFrame && first.frame.rtpTimestamp == 1 && f.coordinator.isHoldingCachedFrame)
    #expect(f.coordinator.select() == nil)  // no redraw requested, nothing incoming
    f.coordinator.setNeedsRedraw()
    #expect(f.queue.pending == 0)  // without redrawsOnDemand a redraw request schedules nothing (unchanged)
    let redraw = try #require(f.coordinator.select())
    #expect(!redraw.isNewFrame && redraw.frame.rtpTimestamp == 1)
    let submission = ControlledSubmission()
    f.coordinator.commit(
      submission, retaining: Retained(redraw.frame), frame: redraw.frame, isNewFrame: false, submittedAt: 2)
    #expect(submission.committed && f.coordinator.inFlight)
    f.mailbox.put(frame(try makeBuffer(), rtp: 2))
    #expect(f.coordinator.select() == nil && f.mailbox.isHolding)  // in flight: the frame stays in the mailbox
    submission.complete()
    #expect(f.queue.drain() == 1 && !f.coordinator.inFlight)
    #expect(f.draws.value == 0)  // display-link drive: completion never requests a draw
    let next = try #require(f.coordinator.select())
    #expect(next.isNewFrame && next.frame.rtpTimestamp == 2)
  }

  @Test func stopReleasesTheCachedFrameAndMailboxWhileTheCoordinatorStaysAlive() throws {
    let f = Fixture(renderOnArrival: true)
    weak var weakCached: CVPixelBuffer?
    weak var weakWaiting: CVPixelBuffer?
    var sizes: [CGSize] = []
    f.coordinator.onFrameSize = { sizes.append($0) }
    try autoreleasepool {
      let cached = try makeBuffer()
      weakCached = cached
      f.mailbox.put(frame(cached, rtp: 1))
      _ = f.queue.drain()  // arrival hop → one draw request
      let selected = try #require(f.coordinator.select())
      f.coordinator.reportSize(CGSize(width: 64, height: 64))
      let submission = ControlledSubmission()
      f.coordinator.commit(
        submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
      submission.complete()
      _ = f.queue.drain()
      let waiting = try makeBuffer()
      weakWaiting = waiting
      f.mailbox.put(frame(waiting, rtp: 2))  // arrives after completion; queued, not yet drawn
    }
    #expect(f.draws.value == 2 && sizes == [CGSize(width: 64, height: 64)])
    #expect(weakCached != nil && weakWaiting != nil && f.coordinator.isHoldingCachedFrame && f.mailbox.isHolding)
    f.coordinator.stop()
    #expect(f.coordinator.stopped && !f.coordinator.isHoldingCachedFrame && !f.mailbox.isHolding)
    #expect(weakCached == nil && weakWaiting == nil)
    #expect(f.coordinator.onFrameSize == nil && f.coordinator.onPresented == nil)
    #expect(f.metrics.snapshot().labels["rendererStopped"] == "true")
    _ = f.queue.drain()  // the queued arrival for frame 2 is inert
    #expect(f.draws.value == 2)
  }

  @Test func inFlightOwnershipIsHeldThroughStopAndReleasedOnlyAtActualCompletion() throws {
    let f = Fixture(renderOnArrival: true)
    weak var weakBuffer: CVPixelBuffer?
    let submission = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      f.mailbox.put(frame(buffer))
      _ = f.queue.drain()
      let selected = try #require(f.coordinator.select())
      f.coordinator.commit(
        submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
    }
    f.coordinator.stop()
    #expect(f.coordinator.inFlight && weakBuffer != nil)  // GPU still owns the buffer: stop must not release it
    #expect(f.counter("renderedFrames") == 0)
    submission.complete()
    submission.forgetInstalledCompletion()
    #expect(weakBuffer == nil && f.counter("renderedFrames") == 1)  // released at completion, telemetry still counted
    #expect(f.queue.drain() == 1 && !f.coordinator.inFlight)
    #expect(f.draws.value == 1)  // the completion hop does not restart the arrival drive after stop
  }

  @Test func presentationHandlerHoldsOnlyScalarsAndIsSilentAfterStop() throws {
    let f = Fixture(renderOnArrival: false)
    var notified: [UInt32] = []
    f.coordinator.onPresented = { notified.append($0) }
    weak var weakBuffer: CVPixelBuffer?
    let first = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      f.mailbox.put(frame(buffer, rtp: 41, receivedAt: 0.5))
      let selected = try #require(f.coordinator.select())
      f.coordinator.commit(
        first, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
      first.complete()
      first.forgetInstalledCompletion()
      _ = f.queue.drain()
    }
    #expect(f.coordinator.isHoldingCachedFrame && weakBuffer != nil)
    // releases the cache; the un-invoked presentation handler is still held by the submission
    f.coordinator.stop()
    #expect(first.holdsPresentationHandler && weakBuffer == nil)
    first.present(at: 1.5)
    // real presentation is still recorded
    #expect(f.counter("presentationCallbacks") == 1 && f.counter("presentedFrames") == 1)
    #expect(f.queue.drain() == 1 && notified.isEmpty)  // but the product is not notified after stop

    let g = Fixture(renderOnArrival: false)
    var live: [UInt32] = []
    g.coordinator.onPresented = { live.append($0) }
    weak var weakLive: CVPixelBuffer?
    let second = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakLive = buffer
      g.mailbox.put(frame(buffer, rtp: 42))
      let selected = try #require(g.coordinator.select())
      g.coordinator.commit(
        second, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
      second.complete()
      second.forgetInstalledCompletion()
      _ = g.queue.drain()
      g.mailbox.put(frame(try makeBuffer(), rtp: 43))
      _ = try #require(g.coordinator.select())  // the cache moves on to frame 43
    }
    #expect(second.holdsPresentationHandler && weakLive == nil)  // the pending handler alone keeps no buffer alive
    second.present(at: 2)
    _ = g.queue.drain()
    #expect(live == [42])
    second.present(at: 0)  // a second delivery is impossible for a real drawable; the handler was consumed
    #expect(g.counter("unpresentedDrawables") == 0)
  }

  @Test func resizeDisplayLinkAndArrivalWorkAfterStopAreInertAndStopRepeats() throws {
    let f = Fixture(renderOnArrival: true)
    f.mailbox.put(frame(try makeBuffer(), rtp: 1))
    _ = f.queue.drain()
    _ = try #require(f.coordinator.select())
    #expect(f.draws.value == 1)
    f.coordinator.stop()
    f.coordinator.setNeedsRedraw()  // resize / fit change
    #expect(f.coordinator.select() == nil)  // display-link or arrival draw: nothing to render
    f.mailbox.put(frame(try makeBuffer(), rtp: 2))  // late decoder delivery: no subscription left
    #expect(f.queue.pending == 0 && f.mailbox.isHolding)
    f.coordinator.arrivalScheduled()  // an arrival hop queued before stop
    #expect(f.coordinator.select() == nil && f.mailbox.isHolding && f.draws.value == 1)
    f.coordinator.reportSize(CGSize(width: 1, height: 1))
    #expect(f.metrics.snapshot().labels["videoSize"] == nil)
    f.coordinator.onPresented = { _ in }
    f.coordinator.onFrameSize = { _ in }
    #expect(f.coordinator.onPresented == nil && f.coordinator.onFrameSize == nil)
    f.coordinator.bind { Issue.record("bind after stop must be ignored") }
    f.coordinator.arrivalScheduled()
    f.coordinator.stop()
    #expect(f.coordinator.stopped && f.draws.value == 1 && f.counter("renderedFrames") == 0)
  }

  /// The reentrant path: select → reportSize → the size callback closes the
  /// renderer → the caller still reaches commit. Commit is refused before any
  /// handler is installed, anything retained or anything submitted.
  @Test func stopInsideTheSizeCallbackRefusesTheHeldSelectionAtCommit() throws {
    let f = Fixture(renderOnArrival: true)
    let coordinator = f.coordinator
    coordinator.onFrameSize = { _ in coordinator.stop() }
    weak var weakBuffer: CVPixelBuffer?
    let submission = ControlledSubmission()
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      f.mailbox.put(frame(buffer))
      _ = f.queue.drain()
      let selected = try #require(coordinator.select())
      coordinator.reportSize(CGSize(width: 64, height: 64))
      #expect(coordinator.stopped)
      let committed = coordinator.commit(
        submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
      #expect(!committed)
    }
    #expect(!submission.committed && !submission.holdsPresentationHandler && !coordinator.inFlight)
    #expect(weakBuffer == nil)  // nothing retained by a refused commit
    submission.complete()
    submission.present(at: 1)
    #expect(f.queue.pending == 0 && f.counter("renderedFrames") == 0 && f.counter("presentationCallbacks") == 0)
  }

  @Test func aSecondCommitWhileTheFirstIsPendingIsRefusedAndRetainsNothing() throws {
    let f = Fixture(renderOnArrival: false)
    let first = ControlledSubmission()
    let second = ControlledSubmission()
    weak var weakSecond: CVPixelBuffer?
    f.mailbox.put(frame(try makeBuffer(), rtp: 1))
    let selected = try #require(f.coordinator.select())
    #expect(
      f.coordinator.commit(
        first, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1))
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakSecond = buffer
      let late = frame(buffer, rtp: 2)
      #expect(
        !f.coordinator.commit(
          second, retaining: Retained(late), frame: late, isNewFrame: true, submittedAt: 2))
    }
    #expect(weakSecond == nil && !second.committed && !second.holdsPresentationHandler)
    #expect(f.coordinator.inFlight && first.committed)
    first.complete()
    #expect(f.queue.drain() == 1 && !f.coordinator.inFlight && f.counter("renderedFrames") == 1)
  }

  /// Distinct order: the GPU completion and the presentation happen while the
  /// renderer is live (their main-actor hops are queued), the renderer stops,
  /// and only then the queued work runs — no draw, no product notification.
  @Test func mainActorWorkQueuedBeforeStopIsInertWhenDrained() throws {
    let f = Fixture(renderOnArrival: true)
    var notified: [UInt32] = []
    f.coordinator.onPresented = { notified.append($0) }
    let submission = ControlledSubmission()
    f.mailbox.put(frame(try makeBuffer(), rtp: 9))
    _ = f.queue.drain()
    #expect(f.draws.value == 1)
    let selected = try #require(f.coordinator.select())
    f.coordinator.commit(
      submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
    submission.complete()  // live: queues the completion hop (would request a draw)
    submission.present(at: 2)  // live: queues the presentation hop (would notify)
    #expect(f.queue.pending == 2 && f.coordinator.inFlight)
    #expect(f.counter("renderedFrames") == 1 && f.counter("presentedFrames") == 1)
    f.coordinator.stop()
    #expect(f.queue.drain() == 2)
    #expect(!f.coordinator.inFlight && f.draws.value == 1 && notified.isEmpty)
    #expect(f.coordinator.select() == nil)
  }

  @Test func stopBeforeAnyFrameAndACompletionErrorAreHandled() throws {
    let f = Fixture(renderOnArrival: true)
    f.coordinator.stop()
    f.mailbox.put(frame(try makeBuffer()))
    #expect(f.queue.pending == 0 && f.coordinator.select() == nil)
    let g = Fixture(renderOnArrival: true)
    g.mailbox.put(frame(try makeBuffer()))
    _ = g.queue.drain()
    let selected = try #require(g.coordinator.select())
    let submission = ControlledSubmission()
    g.coordinator.commit(
      submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
    submission.complete(false)
    #expect(g.counter("renderErrors") == 1 && g.counter("renderedFrames") == 0)
    // live arrival drive continues after an error
    #expect(g.queue.drain() == 1 && !g.coordinator.inFlight && g.draws.value == 2)
  }
}

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
      fitToWindow: false, clearColor: SIMD4(0.1, 0.2, 0.3, 1), drawableSize: size)
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
        geometry: .init(fitToWindow: geometry.fitToWindow, clearColor: geometry.clearColor, drawableSize: size))
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
        with: preparer, geometry: .init(fitToWindow: true, clearColor: .zero, drawableSize: CGSize(width: 8, height: 8))
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
        with: preparer, geometry: .init(fitToWindow: true, clearColor: .zero, drawableSize: CGSize(width: 8, height: 8))
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
