import CoreVideo
import Dispatch
import Foundation
import ScreenSharing

/// How much of a pushed sequence a sink forwards. A sink chooses one of the two policies and the
/// contract holds it to that choice; it is not a quality setting.
public enum ScreenSharingFrameSinkRetention: Sendable {
  /// Every accepted frame reaches the consumer, in push order.
  case everyFrame
  /// Only the newest frame survives until the consumer takes it; the rest are counted as drops.
  case newestFrame
}

/// One frame-sink implementation, wrapped with the few observations the shared contract needs.
/// `ScreenSharingFrameSink` itself is write-only, so an implementation cannot be checked without
/// the owner explaining how its consumer observes delivery.
public protocol ScreenSharingFrameSinkSubject: AnyObject, Sendable {
  var sink: any ScreenSharingFrameSink { get }
  var retention: ScreenSharingFrameSinkRetention { get }
  /// The identities (`timestampNs`) delivered onward since the last take, in order. Taking drains
  /// whatever the sink holds, exactly as the real consumer does.
  func takeDelivered() -> [Int64]
  /// Frames the sink accepted and deliberately dropped, counted since it was created.
  var droppedCount: Int { get }
  /// Ends the sink the way its owner does. Pushes afterwards must not reach a consumer.
  func tearDown()
}

/// The behaviour every frame sink owes its capture source, as data: push ordering, the drop policy
/// under a consumer that never drains, and silence after teardown. It lives in the shared testing
/// target so the WebRTC sender can be held to exactly the same list as an in-memory sink, rather
/// than to a second description of the same contract.
public struct ScreenSharingFrameSinkContract: Sendable, CustomStringConvertible {
  public struct Violation: Error, CustomStringConvertible {
    public let contract: String
    public let reason: String
    public var description: String { "\(contract): \(reason)" }
  }

  public let name: String
  private let body: @Sendable (any ScreenSharingFrameSinkSubject) throws -> Void

  public var description: String { name }

  private init(_ name: String, _ body: @escaping @Sendable (any ScreenSharingFrameSinkSubject) throws -> Void) {
    self.name = name
    self.body = body
  }

  public func check(_ subject: any ScreenSharingFrameSinkSubject) throws { try body(subject) }

  public static let all: [ScreenSharingFrameSinkContract] = [
    .init("a drained consumer receives every frame in push order") { subject in
      var delivered: [Int64] = []
      for identity in Int64(1)...4 {
        subject.sink.push(ScreenSharingFrameSinkContract.frame(identity))
        delivered += subject.takeDelivered()
      }
      try require(delivered == [1, 2, 3, 4], "expected 1...4 in order, got \(delivered)", in: "push order")
      try require(
        subject.droppedCount == 0, "dropped \(subject.droppedCount) with a keeping-up consumer", in: "push order")
    },
    .init("a consumer that never drains applies the sink's stated retention") { subject in
      for identity in Int64(1)...4 { subject.sink.push(ScreenSharingFrameSinkContract.frame(identity)) }
      let delivered = subject.takeDelivered()
      switch subject.retention {
      case .everyFrame:
        try require(
          delivered == [1, 2, 3, 4], "expected every frame in order, got \(delivered)", in: "retention")
        try require(subject.droppedCount == 0, "a queueing sink dropped \(subject.droppedCount)", in: "retention")
      case .newestFrame:
        try require(delivered == [4], "expected only the newest frame, got \(delivered)", in: "retention")
        try require(subject.droppedCount == 3, "expected 3 drops, got \(subject.droppedCount)", in: "retention")
      }
    },
    .init("a push after teardown never reaches a consumer") { subject in
      subject.sink.push(ScreenSharingFrameSinkContract.frame(1))
      subject.tearDown()
      subject.sink.push(ScreenSharingFrameSinkContract.frame(2))
      subject.sink.push(ScreenSharingFrameSinkContract.frame(3))
      let delivered = subject.takeDelivered()
      try require(
        !delivered.contains(2) && !delivered.contains(3),
        "frames pushed after teardown were delivered: \(delivered)", in: "teardown")
    },
    .init("teardown is idempotent") { subject in
      subject.tearDown()
      subject.tearDown()
      subject.sink.push(ScreenSharingFrameSinkContract.frame(1))
      let delivered = subject.takeDelivered()
      try require(delivered.isEmpty, "a torn-down sink delivered \(delivered)", in: "teardown")
    },
    .init("concurrent producers lose no frame") { subject in
      let producers = 8
      let perProducer = 64
      // Every producer parks on one gate and is released together, so the pushes genuinely overlap
      // instead of finishing in whatever order the queue happened to start them.
      let arrived = DispatchGroup()
      let finished = DispatchGroup()
      let gate = DispatchSemaphore(value: 0)
      for producer in 0..<producers {
        arrived.enter()
        finished.enter()
        DispatchQueue.global().async {
          arrived.leave()
          gate.wait()
          for index in 0..<perProducer {
            subject.sink.push(ScreenSharingFrameSinkContract.frame(Int64(producer * perProducer + index + 1)))
          }
          finished.leave()
        }
      }
      arrived.wait()
      for _ in 0..<producers { gate.signal() }
      finished.wait()
      let delivered = subject.takeDelivered()
      let total = producers * perProducer
      try require(
        delivered.count + subject.droppedCount == total,
        "\(delivered.count) delivered plus \(subject.droppedCount) dropped is not \(total)", in: "concurrency")
      if subject.retention == .everyFrame {
        try require(
          Set(delivered) == Set(Int64(1)...Int64(total)),
          "a queueing sink delivered \(Set(delivered).count) distinct frames of \(total)", in: "concurrency")
      }
    },
  ]

  private static func require(_ condition: Bool, _ reason: @autoclosure () -> String, in contract: String) throws {
    guard !condition else { return }
    throw Violation(contract: contract, reason: reason())
  }

  /// A minimal real frame. The identity is the timestamp, which is what a sink forwards and what a
  /// consumer can compare; the pixels are never read.
  public static func frame(_ identity: Int64) -> ScreenSharingVideoFrame {
    var pixel: CVPixelBuffer?
    CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel)
    guard let pixel else { preconditionFailure("A 2x2 BGRA buffer must be allocatable.") }
    return ScreenSharingVideoFrame(pixelBuffer: pixel, timestampNs: identity, sourceTimestampNs: identity)
  }
}

/// A sink that keeps every frame it is given, for a consumer that reads the whole sequence.
public final class ScreenSharingRecordingFrameSink: ScreenSharingFrameSink, ScreenSharingFrameSinkSubject,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var frames: [ScreenSharingVideoFrame] = []
  private var closed = false

  public init() {}

  public var sink: any ScreenSharingFrameSink { self }
  public var retention: ScreenSharingFrameSinkRetention { .everyFrame }
  public var droppedCount: Int { 0 }
  /// Retained frames, for a consumer that needs the buffers rather than the identities.
  public var received: [ScreenSharingVideoFrame] { lock.withLock { frames } }

  public func push(_ frame: ScreenSharingVideoFrame) {
    lock.withLock {
      guard !closed else { return }
      frames.append(frame)
    }
  }

  public func takeDelivered() -> [Int64] {
    lock.withLock {
      defer { frames = [] }
      return frames.map(\.timestampNs)
    }
  }

  public func tearDown() {
    lock.withLock {
      closed = true
      frames = []
    }
  }
}

/// A sink over the product's one-element mailbox: the newest-wins policy the viewer actually runs,
/// without a transport behind it.
public final class ScreenSharingMailboxFrameSink: ScreenSharingFrameSink, ScreenSharingFrameSinkSubject,
  @unchecked Sendable
{
  public let mailbox = ScreenSharingFrameMailbox()
  private let lock = NSLock()
  private var closed = false

  public init() {}

  public var sink: any ScreenSharingFrameSink { self }
  public var retention: ScreenSharingFrameSinkRetention { .newestFrame }
  public var droppedCount: Int { mailbox.droppedFrames }

  public func push(_ frame: ScreenSharingVideoFrame) {
    guard lock.withLock({ !closed }) else { return }
    mailbox.put(frame)
  }

  public func takeDelivered() -> [Int64] {
    guard let frame = mailbox.take() else { return [] }
    return [frame.timestampNs]
  }

  public func tearDown() {
    lock.withLock { closed = true }
    mailbox.clear()
  }
}
