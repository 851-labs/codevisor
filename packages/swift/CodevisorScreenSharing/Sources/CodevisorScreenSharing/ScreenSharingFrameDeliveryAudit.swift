import CoreVideo
import Foundation
import QuartzCore

/// Receiver-only, opt-in frame-delivery audit (diagnostic). Records scalar
/// boundary events for decoded frames on ONE receiver-local clock:
/// `CACurrentMediaTime()` in nanoseconds — the clock of the viewer's media
/// origin, of `receivedAtSeconds`, of Metal's `presentedTime` and of the
/// observer alignment. Identity is a monotonic receiver-side decoder-input
/// sequence (never restarted) plus the RTP timestamp; the identity's
/// `generation` is the decoder INPUT EPOCH (VideoToolbox sessions created
/// before that input); session creation itself is a recorded event. Records hold scalars only: no buffer, texture or object is
/// retained. Disabled (nil) means nothing is allocated and every call site is
/// a single nil branch. Earlier stages (capture, encode, network, jitter
/// buffer before decoder input) and physical scanout are outside this audit.
public final class ScreenSharingFrameDeliveryAudit: @unchecked Sendable {
  public enum Stage: UInt8, CaseIterable, Sendable {
    /// WebRTC handed a reassembled/released encoded frame to the decoder.
    case decoderInput = 1
    /// VideoToolbox output callback delivered the decoded pixel buffer.
    case vtOutput = 2
    /// WebRTC's native renderer callback delivered the frame to the mailbox.
    case rtcRendererCallback = 3
    /// The coordinator selected the frame (new frames only; cached redraws are not deliveries).
    case selection = 4
    /// Drawable acquisition began (main-actor `currentDrawable` or worker `nextDrawable`).
    case acquisitionBegin = 5
    /// Drawable acquisition returned (value = 1 acquired, 0 none).
    case acquisitionEnd = 6
    /// Off-main preparation started on the worker (textures + size + acquisition + encoding).
    case preparationBegin = 7
    /// The prepared result reached the main actor (`finishPreparation`).
    case preparedReceipt = 8
    /// Final submission (commit) after the coordinator's terminal/slot guard.
    case submission = 9
    /// The command buffer's completion CALLBACK ran (value = 1 completed, 0 error).
    case gpuCompletionCallback = 10
    /// The presented handler ran: `atNs` is the callback time, `valueNs` is
    /// Metal's `presentedTime` converted to nanoseconds (0 = unpresented).
    case presentedResult = 11
    /// A VideoToolbox session was created for the frame carrying this identity
    /// (value = the new generation); later inputs carry that epoch.
    case decoderConfigured = 12
    /// The mailbox replaced this (never selected) frame with a newer one —
    /// the newest-frame policy, recorded so downstream absence is explained.
    case mailboxReplaced = 13

    public var name: String {
      switch self {
      case .decoderInput: "decoderInput"
      case .vtOutput: "vtOutput"
      case .rtcRendererCallback: "rtcRendererCallback"
      case .selection: "selection"
      case .acquisitionBegin: "acquisitionBegin"
      case .acquisitionEnd: "acquisitionEnd"
      case .preparationBegin: "preparationBegin"
      case .preparedReceipt: "preparedReceipt"
      case .submission: "submission"
      case .gpuCompletionCallback: "gpuCompletionCallback"
      case .presentedResult: "presentedResult"
      case .decoderConfigured: "decoderConfigured"
      case .mailboxReplaced: "mailboxReplaced"
      }
    }
  }

  /// Decoder-input identity: the sequence never restarts within one audit; the
  /// generation is the input epoch = VideoToolbox sessions created before the
  /// input (the frame that triggers a session keeps the epoch it was input in;
  /// the creation is its own `decoderConfigured` event).
  public struct Identity: Equatable, Hashable, Sendable {
    public let sequence: UInt32
    public let generation: UInt16
    public init(sequence: UInt32, generation: UInt16) {
      self.sequence = sequence
      self.generation = generation
    }
    var packed: UInt64 { UInt64(generation) << 32 | UInt64(sequence) }
    init?(packed: UInt64) {
      let sequence = UInt32(truncatingIfNeeded: packed)
      guard sequence != 0 else { return nil }
      self.init(sequence: sequence, generation: UInt16(truncatingIfNeeded: packed >> 32))
    }
  }

  /// Recording window relative to the receiver-local origin (media start).
  public struct Window: Equatable, Sendable {
    public let beginSeconds: Double
    public let durationSeconds: Double
    public init(beginSeconds: Double, durationSeconds: Double) throws {
      guard beginSeconds.isFinite, durationSeconds.isFinite, beginSeconds >= 0, durationSeconds > 0 else {
        throw ScreenSharingError.invalid("Delivery audit window needs begin >= 0 and a positive duration.")
      }
      self.beginSeconds = beginSeconds
      self.durationSeconds = durationSeconds
    }
  }

  /// 32-byte scalar record (stride); nothing is retained.
  struct Record {
    let stage: UInt8
    let generation: UInt16
    let sequence: UInt32
    let rtpTimestamp: UInt32
    let atNs: Int64
    let valueNs: Int64
  }

  public struct Snapshot: Encodable, Sendable {
    public let kind: String
    public let clock: String
    public let originNs: Int64?
    public let windowBeginSeconds: Double
    public let windowDurationSeconds: Double
    public let windowNs: [Int64]?
    public let capacity: Int
    public let recordByteStride: Int
    public let preallocatedRecordBytes: Int
    public let seenDictionaryEntries: Int
    public let recorded: Int
    public let overflow: Int
    public let beforeOrigin: Int
    public let outsideWindowBefore: Int
    public let outsideWindowAfter: Int
    public let lateAfterClose: Int
    public let missingIdentityEvents: Int
    public let duplicateEvents: Int
    public let closedAtNs: Int64?
    public let firstEventNs: Int64?
    public let lastEventNs: Int64?
    public let decoderGenerations: Int
    public let sequenceRange: [UInt32]?
    public let perStage: [String: Int]
    /// Events counted but never recorded: these make a trace incomplete.
    public let truncation: [String: Int]
    /// Frames reaching each boundary, and downstream absences (which may be
    /// legitimate newest-frame replacement, a failed preparation, or window
    /// clipping — not by themselves an incomplete trace).
    public let coverage: [String: Int]
    public let stages: [UInt8]
    public let generations: [UInt16]
    public let sequences: [UInt32]
    public let rtpTimestamps: [UInt32]
    public let atNs: [Int64]
    public let valueNs: [Int64]
    public let notes: [String]
  }

  public static let defaultCapacity = 65536
  public static let recordByteStride = MemoryLayout<Record>.stride
  /// The one supported clock: CACurrentMediaTime in nanoseconds.
  public static func defaultClock() -> Int64 { Int64(CACurrentMediaTime() * 1_000_000_000) }
  static let attachmentKey = "com.codevisor.screenSharing.deliveryAuditIdentity"

  public let window: Window
  public let capacity: Int
  private let clock: @Sendable () -> Int64
  private let lock = NSLock()
  private var records: [Record]
  private var seen: [UInt32: UInt16] = [:]  // stage bitmask per sequence (bounded by capacity)
  private var nextSequence: UInt32 = 1
  private var generation: UInt16 = 0
  private var originNs: Int64?
  private var closedAtNs: Int64?
  private var overflow = 0
  private var beforeOrigin = 0
  private var outsideBefore = 0
  private var outsideAfter = 0
  private var late = 0
  private var missingIdentity = 0
  private var duplicates = 0
  private var firstEventNs: Int64?
  private var lastEventNs: Int64?

  public init(
    window: Window, capacity: Int = ScreenSharingFrameDeliveryAudit.defaultCapacity,
    clock: @escaping @Sendable () -> Int64 = { ScreenSharingFrameDeliveryAudit.defaultClock() }
  ) {
    self.window = window
    self.capacity = max(1, capacity)
    self.clock = clock
    records = []
    records.reserveCapacity(self.capacity)
    seen.reserveCapacity(min(self.capacity, 8192))
  }

  /// Media start on the receiver-local clock. Events before it are counted, not recorded.
  public func start(originNs: Int64) {
    lock.withLock { if self.originNs == nil { self.originNs = originNs } }
  }

  /// The audit's clock, for explicit stamps taken around a boundary.
  public func now() -> Int64 { clock() }

  /// A VideoToolbox session was created while decoding `identity` (nil when
  /// the triggering input carried none); sequences continue, the epoch of
  /// LATER inputs increments, and the creation is recorded as an event.
  @discardableResult
  public func decoderConfigured(_ identity: Identity?, rtpTimestamp: UInt32) -> UInt16 {
    let next: UInt16 = lock.withLock {
      generation &+= 1
      return generation
    }
    record(.decoderConfigured, identity, rtpTimestamp: rtpTimestamp, valueNs: Int64(next))
    return next
  }

  /// Assigns the next identity at decoder input and records the boundary.
  public func decoderInput(rtpTimestamp: UInt32, atNs: Int64? = nil) -> Identity {
    let identity: Identity = lock.withLock {
      let id = Identity(sequence: nextSequence, generation: generation)
      nextSequence &+= 1
      if nextSequence == 0 { nextSequence = 1 }
      return id
    }
    record(.decoderInput, identity, rtpTimestamp: rtpTimestamp, atNs: atNs)
    return identity
  }

  /// Records one boundary. A nil identity is counted as a missing-identity
  /// event and stored with sequence 0. Events outside the window, before the
  /// origin, after close, or beyond capacity are counted, never recorded.
  public func record(
    _ stage: Stage, _ identity: Identity?, rtpTimestamp: UInt32, valueNs: Int64 = 0, atNs: Int64? = nil
  ) {
    let at = atNs ?? clock()
    lock.withLock {
      guard closedAtNs == nil else { late += 1; return }
      guard let originNs else { beforeOrigin += 1; return }
      let begin = originNs + Int64(window.beginSeconds * 1_000_000_000)
      let end = begin + Int64(window.durationSeconds * 1_000_000_000)
      if at < begin { outsideBefore += 1; return }
      if at >= end { outsideAfter += 1; return }
      guard records.count < capacity else { overflow += 1; return }
      let sequence = identity?.sequence ?? 0
      if identity == nil {
        missingIdentity += 1
      } else {
        let bit = UInt16(1) << UInt16(stage.rawValue)
        let mask = seen[sequence, default: 0]
        if mask & bit != 0 { duplicates += 1 }
        seen[sequence] = mask | bit
      }
      records.append(
        Record(
          stage: stage.rawValue, generation: identity?.generation ?? 0, sequence: sequence, rtpTimestamp: rtpTimestamp,
          atNs: at, valueNs: valueNs))
      // Append order is preserved in the arrays; the bounds are true min/max
      // (the clock is sampled before the lock, so appends can be out of order).
      firstEventNs = min(firstEventNs ?? at, at)
      lastEventNs = max(lastEventNs ?? at, at)
    }
  }

  /// Terminal: later events are counted as late and never recorded.
  public func close(atNs: Int64? = nil) {
    let at = atNs ?? clock()
    lock.withLock { if closedAtNs == nil { closedAtNs = at } }
  }

  // MARK: identity on the decoded pixel buffer (diagnostic-only scalar attachment)

  /// Attaches the identity to a decoded buffer so it survives the RTC native
  /// bridge. Reused pool buffers get a fresh value on every VT output while
  /// the audit is enabled; nothing is attached when the audit is nil.
  public static func attach(_ identity: Identity, to buffer: CVPixelBuffer) {
    CVBufferSetAttachment(buffer, attachmentKey as CFString, NSNumber(value: identity.packed), .shouldNotPropagate)
  }

  /// The bridge helper used at VideoToolbox output while the audit is enabled:
  /// a nil identity CLEARS any previous value so a reused pool buffer can never
  /// carry a stale identity to the renderer. Not called when the audit is off.
  public static func stamp(_ identity: Identity?, on buffer: CVPixelBuffer) {
    if let identity { attach(identity, to: buffer) } else { removeIdentity(from: buffer) }
  }

  public static func readIdentity(from buffer: CVPixelBuffer) -> Identity? {
    guard let value = CVBufferCopyAttachment(buffer, attachmentKey as CFString, nil) as? NSNumber else { return nil }
    return Identity(packed: value.uint64Value)
  }

  public static func removeIdentity(from buffer: CVPixelBuffer) {
    CVBufferRemoveAttachment(buffer, attachmentKey as CFString)
  }

  public var isClosed: Bool { lock.withLock { closedAtNs != nil } }

  public func snapshot() -> Snapshot {
    lock.withLock {
      var perStage: [String: Int] = [:]
      for stage in Stage.allCases { perStage[stage.name] = 0 }
      for r in records { if let stage = Stage(rawValue: r.stage) { perStage[stage.name, default: 0] += 1 } }
      let frames = seen.keys.filter { $0 != 0 }
      func reached(_ stage: Stage) -> Int {
        frames.filter { seen[$0]! & (UInt16(1) << UInt16(stage.rawValue)) != 0 }.count
      }
      func has(_ mask: UInt16, _ stage: Stage) -> Bool { mask & (UInt16(1) << UInt16(stage.rawValue)) != 0 }
      var coverage: [String: Int] = ["framesWithIdentity": frames.count]
      for stage in Stage.allCases { coverage["reached." + stage.name] = reached(stage) }
      coverage["absent.vtOutputAfterDecoderInput"] =
        frames.filter { has(seen[$0]!, .decoderInput) && !has(seen[$0]!, .vtOutput) }.count
      coverage["absent.rendererCallbackAfterVtOutput"] =
        frames.filter { has(seen[$0]!, .vtOutput) && !has(seen[$0]!, .rtcRendererCallback) }.count
      coverage["absent.selectionAfterRendererCallback"] =
        frames.filter { has(seen[$0]!, .rtcRendererCallback) && !has(seen[$0]!, .selection) }.count
      coverage["absent.selectionAfterRendererCallback.mailboxReplaced"] =
        frames.filter {
          has(seen[$0]!, .rtcRendererCallback) && !has(seen[$0]!, .selection) && has(seen[$0]!, .mailboxReplaced)
        }.count
      coverage["absent.submissionAfterSelection"] =
        frames.filter { has(seen[$0]!, .selection) && !has(seen[$0]!, .submission) }.count
      coverage["absent.completionCallbackAfterSubmission"] =
        frames.filter { has(seen[$0]!, .submission) && !has(seen[$0]!, .gpuCompletionCallback) }.count
      coverage["absent.presentedResultAfterSubmission"] =
        frames.filter { has(seen[$0]!, .submission) && !has(seen[$0]!, .presentedResult) }.count
      coverage["presentedResultZero"] =
        records.filter { $0.stage == Stage.presentedResult.rawValue && $0.valueNs == 0 }.count
      records.filter { $0.stage == Stage.presentedResult.rawValue && $0.valueNs == 0 }.count
      let sequences = frames.isEmpty ? nil : [frames.min()!, frames.max()!]
      let begin = originNs.map { $0 + Int64(window.beginSeconds * 1_000_000_000) }
      return Snapshot(
        kind: "receiver-frame-delivery-audit",
        clock:
          "receiver-local CACurrentMediaTime × 1e9 for origin, window and every atNs; presentedResult.valueNs = Metal presentedTime × 1e9 on that same clock (0 = unpresented); gpuCompletionCallback.atNs = when the completion CALLBACK ran, not GPU hardware end",
        originNs: originNs, windowBeginSeconds: window.beginSeconds, windowDurationSeconds: window.durationSeconds,
        windowNs: begin.map { [$0, $0 + Int64(window.durationSeconds * 1_000_000_000)] },
        capacity: capacity, recordByteStride: Self.recordByteStride,
        preallocatedRecordBytes: capacity * Self.recordByteStride,
        seenDictionaryEntries: seen.count,
        recorded: records.count, overflow: overflow, beforeOrigin: beforeOrigin, outsideWindowBefore: outsideBefore,
        outsideWindowAfter: outsideAfter,
        lateAfterClose: late, missingIdentityEvents: missingIdentity, duplicateEvents: duplicates,
        closedAtNs: closedAtNs,
        firstEventNs: firstEventNs, lastEventNs: lastEventNs, decoderGenerations: Int(generation),
        sequenceRange: sequences,
        perStage: perStage,
        truncation: [
          "overflow": overflow, "beforeOrigin": beforeOrigin, "outsideWindowBefore": outsideBefore,
          "outsideWindowAfter": outsideAfter, "lateAfterClose": late, "missingIdentityEvents": missingIdentity,
        ],
        coverage: coverage,
        stages: records.map(\.stage), generations: records.map(\.generation), sequences: records.map(\.sequence),
        rtpTimestamps: records.map(\.rtpTimestamp),
        atNs: records.map(\.atNs), valueNs: records.map(\.valueNs),
        notes: [
          "identity = receiver decoder-input sequence (monotonic across decoder generations) + RTP timestamp; no source code, no remote clock",
          "stages before decoder input (capture, encode, network, jitter buffer) and physical scanout are not covered",
          "truncation counts (overflow, outside-window, late, missing identity) make a trace incomplete; downstream absences are explained per frame (mailboxReplaced, preparedReceipt value 0, window clipping) and are not by themselves incompleteness",
          "memory: preallocatedRecordBytes covers the record array only; the seen dictionary (one entry per identity) and the one-time snapshot/JSON serialization are additional and not bounded by the record stride",
          "observer events relate to these boundaries only by time proximity on the shared local clock, never by an exact code→RTP join",
        ])
    }
  }
}
