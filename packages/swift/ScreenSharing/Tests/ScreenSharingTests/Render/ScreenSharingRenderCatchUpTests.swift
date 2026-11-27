import CoreVideo
import Foundation
import Testing

@testable import ScreenSharing

@MainActor
struct ScreenSharingRenderCatchUpTests {
  private static let periodNs: Int64 = 16_666_667
  private static let starvedWaitNs: Int64 = 14_700_000

  final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowNs: Int64 = 1_000_000_000
    private var scheduled: [(atNs: Int64, work: @Sendable @MainActor () -> Void)] = []

    var clock: ScreenSharingRenderClock {
      ScreenSharingRenderClock(
        now: { [self] in lock.withLock { nowNs } },
        after: { [self] delayNs, work in lock.withLock { scheduled.append((nowNs + delayNs, work)) } })
    }

    var pending: Int { lock.withLock { scheduled.count } }

    @MainActor func advance(to atNs: Int64) {
      let due = lock.withLock {
        nowNs = atNs
        let due = scheduled.filter { $0.atNs <= atNs }
        scheduled.removeAll { $0.atNs <= atNs }
        return due
      }
      for entry in due { entry.work() }
    }
  }

  private final class Submission: ScreenSharingRenderSubmission, @unchecked Sendable {
    private let lock = NSLock()
    private var completed: (@Sendable (Bool) -> Void)?
    private var presented: (@Sendable (Double, Double?) -> Void)?
    func onCompleted(_ handler: @escaping @Sendable (Bool) -> Void) { lock.withLock { completed = handler } }
    func onPresented(_ handler: @escaping @Sendable (Double, Double?) -> Void) { lock.withLock { presented = handler } }
    func commit() {}
    func finish() {
      let (done, shown) = lock.withLock { (completed, presented) }
      shown?(2, nil)
      done?(true)
    }
  }

  private final class Retained: @unchecked Sendable {}

  private final class Preparer: ScreenSharingRenderPreparer, @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding: [(ScreenSharingPreparationRequest, @Sendable (ScreenSharingPreparedSubmission?) -> Void)] =
      []
    var requested: [UInt32] { lock.withLock { history } }
    private var history: [UInt32] = []

    func prepare(
      _ request: ScreenSharingPreparationRequest,
      completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void
    ) {
      lock.withLock {
        history.append(request.frame.rtpTimestamp)
        outstanding.append((request, completion))
      }
    }

    func finish(
      waitedNs: Int64, takingNewer: Bool = false, deferringNewer: Bool = false, failing: Bool = false
    ) -> Submission? {
      guard let (request, completion) = lock.withLock({ outstanding.isEmpty ? nil : outstanding.removeFirst() })
      else { return nil }

      let submission = Submission()
      let newer = takingNewer || deferringNewer || failing ? request.newer?() : nil
      guard !failing else {
        completion(nil)
        return nil
      }

      completion(
        .init(
          submission: submission, retained: Retained(), videoSize: CGSize(width: 64, height: 64),
          replacement: takingNewer ? newer : nil, drawableWaitNs: waitedNs))
      return submission
    }
  }

  private final class Draws: @unchecked Sendable { var count = 0 }

  @MainActor private struct Fixture {
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    let time = ManualClock()
    let preparer = Preparer()
    let draws = Draws()
    let coordinator: ScreenSharingRenderCoordinator
    var presented: [UInt32] { presentedBox.values }
    private let presentedBox = Presented()

    final class Presented { var values: [UInt32] = [] }

    init() {
      coordinator = ScreenSharingRenderCoordinator(
        mailbox: mailbox, metrics: metrics, renderOnArrival: true, redrawsOnDemand: true,
        hop: { work in MainActor.assumeIsolated { work() } }, clock: time.clock)
      let draws = draws
      coordinator.bind { draws.count += 1 }
      let box = presentedBox
      coordinator.onPresented = { box.values.append($0) }
    }

    func counter(_ name: String) -> Int { metrics.counter(name) }

    func frame(_ rtp: UInt32) throws -> ScreenSharingVideoFrame {
      var pixel: CVPixelBuffer?
      CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel)
      return .init(pixelBuffer: try #require(pixel), timestampNs: Int64(rtp), rtpTimestamp: rtp)
    }

    func draw() -> Bool {
      coordinator.prepare(
        with: preparer, geometry: .init(clearColor: SIMD4(0, 0, 0, 1), drawableSize: CGSize(width: 64, height: 64)))
    }

    func arrive(_ rtp: UInt32, at index: Int64, waitedNs: Int64 = 0) throws {
      time.advance(to: 1_000_000_000 + index * ScreenSharingRenderCatchUpTests.periodNs - 3_000_000)
      mailbox.put(try frame(rtp))
      guard draw() else { return }

      preparer.finish(waitedNs: waitedNs)?.finish()
    }
  }

  @Test func aFullRateStreamShortOfDrawablesSkipsOneFrameAndShowsTheNextOnTime() throws {
    let f = Fixture()
    for index in Int64(0)...4 { try f.arrive(UInt32(index), at: index) }
    try f.arrive(5, at: 5, waitedNs: Self.starvedWaitNs)

    try f.arrive(6, at: 6)
    #expect(f.preparer.requested.last == 5)
    try f.arrive(7, at: 7)

    #expect(f.preparer.requested == [0, 1, 2, 3, 4, 5, 7])
    #expect(f.presented == [0, 1, 2, 3, 4, 5, 7])
    #expect(f.counter("renderCatchUps") == 1 && f.counter("renderHeldFramesSuperseded") == 1)
  }

  @Test func catchesUpAtMostOnceASecondHoweverOftenItWaits() throws {
    let f = Fixture()
    for index in Int64(0)...30 {
      try f.arrive(UInt32(index), at: index, waitedNs: index >= 5 ? Self.starvedWaitNs : 0)
    }

    #expect(f.counter("renderCatchUps") == 1 && f.counter("renderHeldFramesSuperseded") == 1)
    #expect(f.preparer.requested.count == 30)
  }

  @Test func aHeldFrameIsShownWhenNoNewerOneArrives() throws {
    let f = Fixture()
    for index in Int64(0)...4 { try f.arrive(UInt32(index), at: index) }
    try f.arrive(5, at: 5, waitedNs: Self.starvedWaitNs)
    try f.arrive(6, at: 6)
    #expect(f.time.pending == 1 && f.preparer.requested.last == 5)
    let drawsBefore = f.draws.count

    f.time.advance(to: 1_000_000_000 + 8 * Self.periodNs)

    #expect(f.draws.count == drawsBefore + 1 && f.draw())
    #expect(f.preparer.requested.last == 6 && f.counter("renderCatchUpFallbacks") == 1)
  }

  @Test(arguments: [Int64(2), 3])
  func aStreamSlowerThanTheDisplayIsNeverHeld(refreshesPerFrame: Int64) throws {
    let f = Fixture()
    for step in Int64(0)...12 {
      try f.arrive(UInt32(step), at: step * refreshesPerFrame, waitedNs: Self.starvedWaitNs)
    }

    #expect(f.preparer.requested == (0...12).map(UInt32.init))
    #expect(f.counter("renderCatchUps") == 0)
  }

  @Test func theMainActorPathCatchesUpFromItsOwnDrawableWait() throws {
    let f = Fixture()
    func commit(_ rtp: UInt32, at index: Int64, waitedNs: Int64 = 0) throws -> Bool {
      f.time.advance(to: 1_000_000_000 + index * Self.periodNs - 3_000_000)
      f.mailbox.put(try f.frame(rtp))
      guard let (frame, isNew) = f.coordinator.select() else { return false }

      let submission = Submission()
      #expect(
        f.coordinator.commit(
          submission, retaining: Retained(), frame: frame, isNewFrame: isNew, submittedAt: 1, drawableWaitNs: waitedNs))
      submission.finish()
      return true
    }
    for index in Int64(0)...4 { #expect(try commit(UInt32(index), at: index)) }
    #expect(try commit(5, at: 5, waitedNs: Self.starvedWaitNs))

    #expect(!(try commit(6, at: 6)))
    #expect(try commit(7, at: 7))
    #expect(f.presented == [0, 1, 2, 3, 4, 5, 7])
  }

  @Test func aFrameTheWorkerSwapsInAfterWaitingIsTheOneShownAndRedrawn() throws {
    let f = Fixture()
    f.time.advance(to: 1_000_000_000)
    f.mailbox.put(try f.frame(1))
    #expect(f.draw())
    f.mailbox.put(try f.frame(2))

    f.preparer.finish(waitedNs: Self.starvedWaitNs, takingNewer: true)?.finish()

    #expect(f.presented == [2] && !f.mailbox.isHolding)
    f.coordinator.setNeedsRedraw()
    #expect(f.draw() && f.preparer.requested == [1, 2])
  }

  @Test func aNewerFrameTheWorkerCouldNotDrawIsShownNextInsteadOfLost() throws {
    let f = Fixture()
    f.time.advance(to: 1_000_000_000)
    f.mailbox.put(try f.frame(1))
    #expect(f.draw())
    f.mailbox.put(try f.frame(2))

    f.preparer.finish(waitedNs: Self.starvedWaitNs, deferringNewer: true)?.finish()

    #expect(f.presented == [1] && !f.mailbox.isHolding)
    #expect(f.draw() && f.preparer.requested == [1, 2])
    f.preparer.finish(waitedNs: 0)?.finish()
    #expect(f.presented == [1, 2])
  }

  @Test func aNewerFrameTakenForADrawThatFailedIsShownNext() throws {
    let f = Fixture()
    f.time.advance(to: 1_000_000_000)
    f.mailbox.put(try f.frame(1))
    #expect(f.draw())
    f.mailbox.put(try f.frame(2))

    _ = f.preparer.finish(waitedNs: Self.starvedWaitNs, failing: true)

    #expect(!f.mailbox.isHolding && f.draw())
    #expect(f.preparer.requested == [1, 2])
  }

  @Test func aRedrawAskedForDuringAHoldIsDrawnWhenTheHoldEnds() throws {
    let f = Fixture()
    for index in Int64(0)...4 { try f.arrive(UInt32(index), at: index) }
    try f.arrive(5, at: 5, waitedNs: Self.starvedWaitNs)
    f.time.advance(to: 1_000_000_000 + 5 * Self.periodNs + 2_000_000)
    f.coordinator.setNeedsRedraw()
    #expect(!f.draw() && f.time.pending == 1)
    let drawsBefore = f.draws.count

    f.time.advance(to: 1_000_000_000 + 8 * Self.periodNs)

    #expect(f.draws.count == drawsBefore + 1 && f.draw())
    #expect(f.preparer.requested.last == 5)
  }
}
