import CoreVideo
import Foundation
import Testing

@testable import ScreenSharing

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

extension ScreenSharingRenderCoordinatorTests {
  /// The diagnostic presentation hook carries the frame's clocks and in-band identity, fires only for
  /// real presentations, and is cleared by `stop()` like the product notification.
  @Test func framePresentedHookCarriesIdentityAndClocks() throws {
    let f = Fixture(renderOnArrival: false)
    var presented: [ScreenSharingPresentedFrame] = []
    f.coordinator.onFramePresented = { presented.append($0) }
    var notified = 0
    f.coordinator.onPresented = { _ in notified += 1 }
    let submission = ControlledSubmission()
    let buffer = try makeBuffer()
    let frame = ScreenSharingVideoFrame(
      pixelBuffer: buffer, timestampNs: 7, rtpTimestamp: 41, receivedAtSeconds: 0.5, sourceTimestampNs: 123_000_000)
    f.mailbox.put(frame)
    let selected = try #require(f.coordinator.select())
    f.coordinator.commit(
      submission, retaining: Retained(selected.frame), frame: selected.frame, isNewFrame: true, submittedAt: 1)
    submission.complete()
    _ = f.queue.drain()
    // An untimed presentation (presentedTime 0, as a sparsely presented layer reports) still
    // notifies the product — the frame is on screen — but carries no clocks for the diagnostic hook.
    submission.present(at: 0)
    #expect(f.queue.drain() == 1 && notified == 1 && presented.isEmpty)
    let second = ControlledSubmission()
    f.mailbox.put(frame)
    let again = try #require(f.coordinator.select())
    f.coordinator.commit(second, retaining: Retained(again.frame), frame: again.frame, isNewFrame: true, submittedAt: 2)
    second.complete()
    _ = f.queue.drain()
    second.present(at: 2.5)
    #expect(f.queue.drain() == 1)
    #expect(
      presented == [
        ScreenSharingPresentedFrame(
          presentedAtSeconds: 2.5, submittedAtSeconds: 2, receivedAtSeconds: 0.5, sourceTimestampNs: 123_000_000,
          rtpTimestamp: 41)
      ])
    f.coordinator.stop()
    #expect(f.coordinator.onFramePresented == nil)
  }

  /// A new frame dropped before submission (no drawable yet, encoding refused)
  /// still owes its presentation: the redraw it schedules re-selects the cached
  /// frame as new, exactly once; an ordinary redraw stays not-new; nothing after stop.
  @Test func aDroppedNewFrameOwesItsPresentationToTheNextRedraw() throws {
    let f = Fixture(renderOnArrival: false)
    f.mailbox.put(frame(try makeBuffer(), rtp: 3))
    let dropped = try #require(f.coordinator.select())
    #expect(dropped.isNewFrame)
    f.coordinator.deferPresentation()
    let owed = try #require(f.coordinator.select())
    #expect(owed.isNewFrame && owed.frame.rtpTimestamp == 3)
    #expect(f.coordinator.select() == nil)
    f.coordinator.setNeedsRedraw()
    let plain = try #require(f.coordinator.select())
    #expect(!plain.isNewFrame)
    // A newer incoming frame supersedes an owed presentation: it is new on its own.
    f.coordinator.deferPresentation()
    f.mailbox.put(frame(try makeBuffer(), rtp: 4))
    let newer = try #require(f.coordinator.select())
    #expect(newer.isNewFrame && newer.frame.rtpTimestamp == 4)
    #expect(f.coordinator.select() == nil)
    f.coordinator.stop()
    f.coordinator.deferPresentation()
    #expect(f.coordinator.select() == nil)
  }
}
