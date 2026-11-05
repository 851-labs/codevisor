import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

public enum HardwareEncoderBudget {
  public typealias SessionOpener = @Sendable (_ width: Int, _ height: Int) -> VTCompressionSession?

  private static let maximumSessionsPerTest = 6
  private static let probeLimit = DispatchTimeInterval.seconds(10)
  private static let probeWidth = 640
  private static let probeHeight = 180

  public static func require(sessions needed: Int, opening open: @escaping SessionOpener) async throws {
    try #require(
      needed <= maximumSessionsPerTest, "A test may hold at most \(maximumSessionsPerTest) hardware encoder sessions.")

    guard let opened = await probe(needed, open) else {
      try Test.cancel("Skipped: opening \(needed) hardware HEVC encoder sessions didn't finish in \(probeLimit).")
    }
    guard opened >= needed else {
      try Test.cancel(
        "Skipped: this Mac opened only \(opened) of the \(needed) low-latency hardware HEVC encoder sessions this test needs. Another process may be holding them."
      )
    }
  }

  private static func probe(_ count: Int, _ open: @escaping SessionOpener) async -> Int? {
    await withCheckedContinuation { continuation in
      let result = ResumeOnce(continuation)
      Thread.detachNewThread { result.resume(with: workingSessions(upTo: count, open)) }
      DispatchQueue.global().asyncAfter(deadline: .now() + probeLimit) { result.resume(with: nil) }
    }
  }

  private static func workingSessions(upTo count: Int, _ open: SessionOpener) -> Int {
    var sessions: [VTCompressionSession] = []
    defer { sessions.forEach { VTCompressionSessionInvalidate($0) } }
    guard let pixels = blankFrame() else { return 0 }

    while sessions.count < count, let session = open(probeWidth, probeHeight) {
      sessions.append(session)
      guard encodes(session, pixels) else { return sessions.count - 1 }
    }
    return sessions.count
  }

  private static func blankFrame() -> CVPixelBuffer? {
    var pixels: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    CVPixelBufferCreate(
      kCFAllocatorDefault, probeWidth, probeHeight, kCVPixelFormatType_32BGRA, attributes, &pixels)
    return pixels
  }

  private static func encodes(_ session: VTCompressionSession, _ pixels: CVPixelBuffer) -> Bool {
    let encoded = TestSignal()
    let status = VTCompressionSessionEncodeFrame(
      session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: 0, timescale: 600), duration: .invalid,
      frameProperties: nil, infoFlagsOut: nil
    ) { status, _, sample in
      if status == noErr, sample != nil { encoded.signal() }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    return status == noErr && encoded.value == 1
  }
}
