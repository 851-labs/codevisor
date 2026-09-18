import CoreVideo
import Foundation
import QuartzCore
import Testing

@testable import ScreenSharing

/// The receiver-only frame-delivery audit: injected clock, window edges,
/// capacity/overflow, identity across decoder generations and reused buffers,
/// duplicates/missing/out-of-order/late events, scalar-only records.
struct ScreenSharingFrameDeliveryAuditTests {
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    private(set) var reads = 0
    func set(_ ns: Int64) { lock.withLock { value = ns } }
    var read: @Sendable () -> Int64 {
      { [self] in
        self.lock.withLock {
          self.reads += 1; return self.value
        }
      }
    }
  }

  private func audit(
    begin: Double = 1, duration: Double = 2, capacity: Int = 64
  ) throws -> (ScreenSharingFrameDeliveryAudit, Clock) {
    let clock = Clock()
    let audit = ScreenSharingFrameDeliveryAudit(
      window: try .init(beginSeconds: begin, durationSeconds: duration), capacity: capacity, clock: clock.read)
    return (audit, clock)
  }

  private func makeBuffer() throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return try #require(pixel)
  }

  @Test func windowEdgesOriginAndCapacityAreExact() throws {
    let (audit, clock) = try audit(begin: 1, duration: 2, capacity: 3)
    clock.set(500)
    audit.record(.decoderInput, .init(sequence: 1, generation: 1), rtpTimestamp: 10)  // before the origin is known
    audit.start(originNs: 1_000_000_000)
    audit.start(originNs: 5)  // a second start is ignored
    // 1 ns before the window
    clock.set(1_999_999_999); audit.record(.decoderInput, .init(sequence: 1, generation: 1), rtpTimestamp: 10)
    // begin is inclusive
    clock.set(2_000_000_000); audit.record(.decoderInput, .init(sequence: 2, generation: 1), rtpTimestamp: 11)
    // last ns inside
    clock.set(3_999_999_999); audit.record(.vtOutput, .init(sequence: 2, generation: 1), rtpTimestamp: 11)
    // end is exclusive
    clock.set(4_000_000_000); audit.record(.rtcRendererCallback, .init(sequence: 2, generation: 1), rtpTimestamp: 11)
    clock.set(3_000_000_000)
    audit.record(.selection, .init(sequence: 2, generation: 1), rtpTimestamp: 11)
    audit.record(.submission, .init(sequence: 2, generation: 1), rtpTimestamp: 11)  // capacity 3 reached here
    let s = audit.snapshot()
    #expect(s.originNs == 1_000_000_000 && s.windowNs == [2_000_000_000, 4_000_000_000])
    #expect((s.beforeOrigin, s.outsideWindowBefore, s.outsideWindowAfter, s.recorded, s.overflow) == (1, 1, 1, 3, 1))
    #expect(s.firstEventNs == 2_000_000_000 && s.lastEventNs == 3_999_999_999)  // true min/max, not first/last append
    #expect(s.stages == [1, 2, 4] && s.sequences == [2, 2, 2] && s.rtpTimestamps == [11, 11, 11])
    #expect(
      s.preallocatedRecordBytes == 3 * ScreenSharingFrameDeliveryAudit.recordByteStride && s.recordByteStride == 32)
    #expect(s.seenDictionaryEntries == 1)
  }

  @Test func inputEpochsAndConfiguredEventsFollowTheRealInputConfigureOutputOrder() throws {
    let (audit, clock) = try audit()
    audit.start(originNs: 0); clock.set(1_500_000_000)
    // first frame: input (epoch 0) -> its decode creates the VT session -> output carries epoch 0
    let a = audit.decoderInput(rtpTimestamp: 100)
    #expect(a == .init(sequence: 1, generation: 0))
    #expect(audit.decoderConfigured(a, rtpTimestamp: 100) == 1)
    audit.record(.vtOutput, a, rtpTimestamp: 100)
    // frames decoded by that session carry epoch 1
    let b = audit.decoderInput(rtpTimestamp: 101)
    #expect(b == .init(sequence: 2, generation: 1))
    // a reset: the triggering frame was input in epoch 1, the new session is event 2, later inputs are epoch 2
    let c = audit.decoderInput(rtpTimestamp: 102)
    #expect(audit.decoderConfigured(c, rtpTimestamp: 102) == 2 && c.generation == 1)
    let d = audit.decoderInput(rtpTimestamp: 103)
    #expect(d == .init(sequence: 4, generation: 2))  // the global sequence never restarts
    let s = audit.snapshot()
    #expect(s.decoderGenerations == 2 && s.sequenceRange == [1, 4] && s.perStage["decoderConfigured"] == 2)
    let configured = zip(s.stages, zip(s.sequences, s.valueNs)).filter { $0.0 == 12 }.map { $0.1 }
    #expect(configured.map { $0.0 } == [1, 3] && configured.map { $0.1 } == [1, 2])
  }

  @Test func theBridgeStampClearsAStaleIdentityOnAReusedBuffer() throws {
    let buffer = try makeBuffer()
    #expect(ScreenSharingFrameDeliveryAudit.readIdentity(from: buffer) == nil)
    let a = ScreenSharingFrameDeliveryAudit.Identity(sequence: 1, generation: 0)
    let b = ScreenSharingFrameDeliveryAudit.Identity(sequence: 2, generation: 0)
    ScreenSharingFrameDeliveryAudit.stamp(a, on: buffer)
    #expect(ScreenSharingFrameDeliveryAudit.readIdentity(from: buffer) == a)
    ScreenSharingFrameDeliveryAudit.stamp(nil, on: buffer)  // an output without identity clears the reused buffer
    #expect(ScreenSharingFrameDeliveryAudit.readIdentity(from: buffer) == nil)
    ScreenSharingFrameDeliveryAudit.stamp(b, on: buffer)
    #expect(ScreenSharingFrameDeliveryAudit.readIdentity(from: buffer) == b)
    ScreenSharingFrameDeliveryAudit.removeIdentity(from: buffer)
    #expect(ScreenSharingFrameDeliveryAudit.readIdentity(from: buffer) == nil)
    // Not exercised here: the disabled decoder/bridge path. That guarantee is the source's nil guards —
    // ScreenSharingDecoder's VT output `if let audit = context.audit { stamp…; record… }` and
    // ScreenSharingPeerRenderer's `if let audit { readIdentity…; record… }` — which never call stamp/read
    // when the audit is nil; those private paths need a decoded frame and are not unit-testable without media.
  }

  @Test func outOfOrderSuppliedTimestampsKeepAppendOrderWithTrueMinMaxBounds() throws {
    let (audit, _) = try audit(begin: 0, duration: 10)
    audit.start(originNs: 0)
    let id = ScreenSharingFrameDeliveryAudit.Identity(sequence: 1, generation: 0)
    audit.record(.submission, id, rtpTimestamp: 1, atNs: 2_000_000_000)
    audit.record(.selection, id, rtpTimestamp: 1, atNs: 1_000_000_000)  // appended later, earlier stamp
    audit.record(.gpuCompletionCallback, id, rtpTimestamp: 1, valueNs: 1, atNs: 3_000_000_000)
    let s = audit.snapshot()
    #expect(s.atNs == [2_000_000_000, 1_000_000_000, 3_000_000_000])  // append order preserved
    #expect(s.firstEventNs == 1_000_000_000 && s.lastEventNs == 3_000_000_000)  // true bounds
  }

  @Test func anAuditConstructedWithTheDefaultClockStampsOnCACurrentMediaTimeInNanoseconds() throws {
    // default clock
    let audit = ScreenSharingFrameDeliveryAudit(window: try .init(beginSeconds: 0, durationSeconds: 10))
    let before = Int64(CACurrentMediaTime() * 1_000_000_000)
    let now = audit.now()
    audit.start(originNs: before)
    audit.record(.selection, .init(sequence: 1, generation: 0), rtpTimestamp: 1)  // stamped by the default clock
    let after = Int64(CACurrentMediaTime() * 1_000_000_000)
    let s = audit.snapshot()
    #expect(before <= now && now <= after)
    #expect(s.atNs.count == 1 && before <= s.atNs[0] && s.atNs[0] <= after)
    #expect(ScreenSharingFrameDeliveryAudit.defaultClock() >= after)
    let (injected, clock) = try self.audit()
    clock.set(123)
    #expect(injected.now() == 123)  // an injected clock replaces the default entirely
  }

  @Test func mailboxReplacementIsObservableAsAScalarEvent() throws {
    let (audit, clock) = try audit(begin: 0, duration: 10)
    audit.start(originNs: 0); clock.set(1_000)
    let mailbox = ScreenSharingFrameMailbox()
    let first = ScreenSharingVideoFrame(
      pixelBuffer: try makeBuffer(), timestampNs: 1, rtpTimestamp: 11,
      deliveryAuditIdentity: .init(sequence: 1, generation: 0))
    #expect(mailbox.put(first) == nil)
    let replaced = mailbox.put(
      .init(
        pixelBuffer: try makeBuffer(), timestampNs: 2, rtpTimestamp: 12,
        deliveryAuditIdentity: .init(sequence: 2, generation: 0)))
    // policy unchanged: newest wins, replacement counted
    #expect(replaced?.rtpTimestamp == 11 && mailbox.droppedFrames == 1)
    audit.record(.rtcRendererCallback, first.deliveryAuditIdentity, rtpTimestamp: 11)
    audit.record(.mailboxReplaced, replaced?.deliveryAuditIdentity, rtpTimestamp: replaced?.rtpTimestamp ?? 0)
    let s = audit.snapshot()
    #expect(s.perStage["mailboxReplaced"] == 1 && s.coverage["absent.selectionAfterRendererCallback"] == 1)
    #expect(s.coverage["absent.selectionAfterRendererCallback.mailboxReplaced"] == 1)  // the absence is explained
    #expect(s.truncation["missingIdentityEvents"] == 0 && s.truncation["overflow"] == 0)
  }

  @Test func duplicatesMissingIdentitiesOutOfOrderAndLateEventsAreDeclaredNotPaired() throws {
    let (audit, clock) = try audit()
    audit.start(originNs: 0); clock.set(1_500_000_000)
    let id = audit.decoderInput(rtpTimestamp: 7)
    // out of order: presented before submission, zero presented time
    audit.record(.presentedResult, id, rtpTimestamp: 7, valueNs: 0)
    audit.record(.submission, id, rtpTimestamp: 7)
    audit.record(.submission, id, rtpTimestamp: 7)  // duplicate stage for the same identity
    audit.record(.rtcRendererCallback, nil, rtpTimestamp: 8)  // a frame whose buffer carried no identity
    audit.close()
    audit.record(.gpuCompletionCallback, id, rtpTimestamp: 7, valueNs: 1)  // late after close
    _ = audit.decoderInput(rtpTimestamp: 9)  // identity is still assigned but the event is late
    let s = audit.snapshot()
    #expect(
      s.recorded == 5 && s.duplicateEvents == 1 && s.missingIdentityEvents == 1 && s.lateAfterClose == 2
        && s.closedAtNs == 1_500_000_000)
    #expect(
      s.coverage["presentedResultZero"] == 1 && s.coverage["absent.completionCallbackAfterSubmission"] == 1
        && s.coverage["framesWithIdentity"] == 1)
    #expect(s.coverage["reached.presentedResult"] == 1 && s.coverage["absent.vtOutputAfterDecoderInput"] == 1)
    #expect(s.truncation["lateAfterClose"] == 2 && s.truncation["missingIdentityEvents"] == 1)
    // missing identity stored as sequence 0, never paired
    #expect(s.sequences.contains(0) && s.perStage["rtcRendererCallback"] == 1)
    #expect(audit.isClosed)
  }

  @Test func explicitTimestampsAreUsedWithoutReadingTheClock() throws {
    let (audit, clock) = try audit()
    audit.start(originNs: 0)
    let before = clock.reads
    audit.record(.acquisitionBegin, .init(sequence: 1, generation: 1), rtpTimestamp: 1, atNs: 1_200_000_000)
    audit.record(.acquisitionEnd, .init(sequence: 1, generation: 1), rtpTimestamp: 1, valueNs: 1, atNs: 1_210_000_000)
    #expect(clock.reads == before)
    let s = audit.snapshot()
    #expect(s.atNs == [1_200_000_000, 1_210_000_000] && s.valueNs == [0, 1])
  }

  @Test func recordsHoldScalarsOnlyAndBuffersAreReleased() throws {
    let (audit, clock) = try audit()
    audit.start(originNs: 0); clock.set(1_500_000_000)
    weak var weakBuffer: CVPixelBuffer?
    try autoreleasepool {
      let buffer = try makeBuffer()
      weakBuffer = buffer
      let id = audit.decoderInput(rtpTimestamp: 3)
      ScreenSharingFrameDeliveryAudit.attach(id, to: buffer)
      audit.record(.vtOutput, ScreenSharingFrameDeliveryAudit.readIdentity(from: buffer), rtpTimestamp: 3)
      let frame = ScreenSharingVideoFrame(
        pixelBuffer: buffer, timestampNs: 1, rtpTimestamp: 3, deliveryAuditIdentity: id)
      audit.record(.rtcRendererCallback, frame.deliveryAuditIdentity, rtpTimestamp: frame.rtpTimestamp)
    }
    #expect(weakBuffer == nil)  // three recorded events, no retained buffer
    #expect(audit.snapshot().recorded == 3)
  }

  @Test func frameIdentityDefaultsToNilWhenTheAuditIsOff() throws {
    let frame = ScreenSharingVideoFrame(pixelBuffer: try makeBuffer(), timestampNs: 1)
    #expect(frame.deliveryAuditIdentity == nil)
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingFrameDeliveryAudit.Window(beginSeconds: -1, durationSeconds: 1)
    }
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingFrameDeliveryAudit.Window(beginSeconds: 0, durationSeconds: 0)
    }
  }
}
