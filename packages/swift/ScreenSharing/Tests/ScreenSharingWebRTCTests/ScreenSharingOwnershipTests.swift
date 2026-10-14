import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

struct ScreenSharingOwnershipTests {
  private func makeBuffer(width: Int = 64) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, width, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return try #require(pixel)
  }

  @Test func cacheReplacementAndClearReleaseThePreviousBufferOnly() throws {
    var store = ScreenSharingRefreshFrameStore()
    weak var weakA: CVPixelBuffer?
    weak var weakB: CVPixelBuffer?
    try autoreleasepool {
      let a = try makeBuffer()
      weakA = a
      #expect(store.capture(.init(pixelBuffer: a, timestampNs: 10)) != nil)
    }
    #expect(weakA != nil && store.isHolding)
    try autoreleasepool {
      let b = try makeBuffer()
      weakB = b
      #expect(store.capture(.init(pixelBuffer: b, timestampNs: 20)) != nil)
    }
    #expect(weakA == nil && weakB != nil)
    try autoreleasepool {
      let refreshed = store.refresh(nowNs: 30)
      let handed = try #require(refreshed)
      #expect(handed.pixelBuffer === weakB)
    }
    #expect(weakB != nil)
    store.clear()
    #expect(weakB == nil && !store.isHolding)
    #expect(store.capture(.init(pixelBuffer: try makeBuffer(), timestampNs: 20)) == nil)
    #expect(store.capture(.init(pixelBuffer: try makeBuffer(), timestampNs: 21))?.timestampNs == 31)
  }

  @Test func mailboxTakeTransfersOwnershipAndClearReleases() throws {
    let mailbox = ScreenSharingFrameMailbox()
    weak var weakA: CVPixelBuffer?
    weak var weakB: CVPixelBuffer?
    try autoreleasepool {
      let a = try makeBuffer()
      weakA = a
      mailbox.put(.init(pixelBuffer: a, timestampNs: 1))
    }
    #expect(weakA != nil)
    try autoreleasepool {
      let b = try makeBuffer()
      weakB = b
      mailbox.put(.init(pixelBuffer: b, timestampNs: 2))
    }
    #expect(weakA == nil && weakB != nil)
    try autoreleasepool {
      let taken = try #require(mailbox.take())
      #expect(taken.pixelBuffer === weakB)
      #expect(mailbox.take() == nil)
    }
    #expect(weakB == nil)
    try autoreleasepool {
      let c = try makeBuffer()
      weakA = c
      mailbox.put(.init(pixelBuffer: c, timestampNs: 3))
    }
    mailbox.clear()
    #expect(weakA == nil)
  }

  @Test @MainActor func senderReleasesCacheOnConfigurationAndRejectsFramesAfterStop() throws {
    ScreenSharingFieldTrials.process.ensureInstalled()
    let factory = RTCPeerConnectionFactory()
    let source = factory.videoSource(forScreenCast: true)
    let metrics = ScreenSharingMetrics()
    let sender = ScreenSharingFrameSender(
      source: source, metrics: metrics, idleMonitor: ScreenSharingSourceIdleMonitor())
    sender.configure(try ScreenSharingVideoConfiguration(width: 128, height: 64))
    weak var weakOld: CVPixelBuffer?
    weak var weakNew: CVPixelBuffer?
    weak var weakLate: CVPixelBuffer?
    try autoreleasepool {
      let old = try makeBuffer(width: 128)
      weakOld = old
      sender.push(.init(pixelBuffer: old, timestampNs: 10))
    }
    #expect(weakOld != nil && sender.isHoldingCachedFrame)
    #expect(metrics.snapshot().counters["capturedFrames"] == 1)
    #expect(
      metrics.snapshot().counters["refreshCacheFills"] == 1
        && metrics.snapshot().counters["refreshCacheReplacements"] == nil)
    sender.configure(try ScreenSharingVideoConfiguration(width: 64, height: 64))
    #expect(weakOld == nil && !sender.isHoldingCachedFrame)
    #expect(metrics.snapshot().counters["refreshCacheReleases"] == 1)
    try autoreleasepool {
      let stale = try makeBuffer(width: 128)
      weakLate = stale
      sender.push(.init(pixelBuffer: stale, timestampNs: 20))
    }
    #expect(weakLate == nil && metrics.snapshot().counters["captureTransitionDrops"] == 1)
    try autoreleasepool {
      let fresh = try makeBuffer(width: 64)
      weakNew = fresh
      sender.push(.init(pixelBuffer: fresh, timestampNs: 30))
    }
    #expect(weakNew != nil && metrics.snapshot().counters["capturedFrames"] == 2)
    #expect(metrics.snapshot().counters["refreshCacheFills"] == 2)
    sender.stop()
    #expect(weakNew == nil && !sender.isHoldingCachedFrame)
    #expect(metrics.snapshot().counters["refreshCacheReleases"] == 2)
    try autoreleasepool {
      let late = try makeBuffer(width: 64)
      weakLate = late
      sender.push(.init(pixelBuffer: late, timestampNs: 40))
      sender.refreshLatest()
    }
    #expect(weakLate == nil && metrics.snapshot().counters["capturedFrames"] == 2)
    #expect(metrics.snapshot().counters["refreshFrames"] == nil)
  }

  @Test @MainActor func peerCloseReleasesCachedMediaAndRejectsLaterCaptureCallbacks() async throws {
    let metrics = ScreenSharingMetrics()
    let peer = try await ScreenSharingSender(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: metrics)
    weak var weakCached: CVPixelBuffer?
    try autoreleasepool {
      let cached = try makeBuffer(width: 64)
      weakCached = cached
      peer.frameSender.push(.init(pixelBuffer: cached, timestampNs: 10))
    }
    #expect(weakCached != nil && peer.frameSender.isHoldingCachedFrame)
    peer.close()
    peer.close()
    #expect(weakCached == nil && !peer.frameSender.isHoldingCachedFrame)
    weak var weakLate: CVPixelBuffer?
    try autoreleasepool {
      let late = try makeBuffer(width: 64)
      weakLate = late
      peer.frameSender.push(.init(pixelBuffer: late, timestampNs: 20))
    }
    #expect(weakLate == nil && metrics.snapshot().counters["capturedFrames"] == 1)
    #expect(metrics.snapshot().counters["refreshCacheFills"] == 1)
    #expect(metrics.snapshot().counters["refreshCacheReleases"] == 1)
  }

  @Test @MainActor func closeBoundaryIsSharedByConcurrentWaitersAndAbsentBeforeClose() async throws {
    let metrics = ScreenSharingMetrics()
    let peer = try await ScreenSharingSender(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: metrics)
    #expect(await peer.awaitClosed() == nil)
    peer.frameSender.push(.init(pixelBuffer: try makeBuffer(), timestampNs: 10))
    #expect(metrics.snapshot().counters["capturedFrames"] == 1)
    peer.close()
    async let first = peer.awaitClosed()
    async let second = peer.awaitClosed()
    let counts = await [first, second]
    #expect(counts[0] != nil && counts[0] == counts[1])
    #expect(await peer.awaitClosed() == counts[0])
  }

  @Test @MainActor func ownedWorkJoinIsSharedByConcurrentWaitersWhileAHandleIsStillPending() async {
    let work = ScreenSharingOwnedWork()
    #expect(await work.join() == nil)
    let gate = TestSignal()
    let released = TestSignal()
    let pending = Task { @MainActor in
      await gate.wait()
      released.signal()
    }
    work.close(with: [pending])
    work.close(with: [])
    let entered = TestSignal()
    let finished = TestSignal()
    async let first: Int? = {
      entered.signal()
      let count = await work.join()
      finished.signal()
      return count
    }()
    async let second: Int? = {
      entered.signal()
      let count = await work.join()
      finished.signal()
      return count
    }()
    await entered.wait(for: 2)
    #expect(finished.value == 0)
    #expect(released.value == 0)
    gate.signal()
    let counts = await [first, second]
    await finished.wait(for: 2)
    #expect(released.value == 1)
    #expect(counts == [1, 1])
    #expect(await work.join() == 1)
  }

  @Test func mailboxOwnershipObservationDoesNotConsumeTheFrame() throws {
    let mailbox = ScreenSharingFrameMailbox()
    #expect(!mailbox.isHolding)
    mailbox.put(.init(pixelBuffer: try makeBuffer(), timestampNs: 1))
    #expect(mailbox.isHolding && mailbox.isHolding)
    #expect(mailbox.take() != nil && !mailbox.isHolding)
  }
}
