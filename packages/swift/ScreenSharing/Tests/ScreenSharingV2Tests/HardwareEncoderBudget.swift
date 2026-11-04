import CodevisorTestSupport
import CoreMedia
import Foundation
import Testing
import VideoToolbox

@testable import ScreenSharingV2

enum HardwareEncoderBudget {
  static let maximumSessionsPerTest = 6
  static let sessionsPerVCPTile = 2
  private static let probeLimit = DispatchTimeInterval.seconds(10)
  private static let probeWidth = 640
  private static let probeHeight = 180

  static func require(vcpTiles: Int = 0, videoToolboxTiles: Int = 0) async throws {
    let needed = vcpTiles * sessionsPerVCPTile + videoToolboxTiles
    try #require(
      needed <= maximumSessionsPerTest, "A test may hold at most \(maximumSessionsPerTest) hardware encoder sessions.")

    guard let opened = await probe(needed) else {
      try Test.cancel("Skipped: opening \(needed) hardware HEVC encoder sessions didn't finish in \(probeLimit).")
    }
    guard opened >= needed else {
      try Test.cancel(
        "Skipped: this Mac opened only \(opened) of the \(needed) low-latency hardware HEVC encoder sessions this test needs. Another process may be holding them."
      )
    }
  }

  private static func probe(_ count: Int) async -> Int? {
    await withCheckedContinuation { continuation in
      let result = ResumeOnce(continuation)
      Thread.detachNewThread { result.resume(with: workingSessions(upTo: count)) }
      DispatchQueue.global().asyncAfter(deadline: .now() + probeLimit) { result.resume(with: nil) }
    }
  }

  private static func workingSessions(upTo count: Int) -> Int {
    let factory = ScreenSharingVideoToolboxSessionFactory(
      width: probeWidth, height: probeHeight, framesPerSecond: 60, bitrate: 1_000_000)
    var sessions: [VTCompressionSession] = []
    defer { sessions.forEach { VTCompressionSessionInvalidate($0) } }
    guard let frame = try? TestBGRAPixels.frame(width: probeWidth, height: probeHeight, shades: [128], timestampNs: 0)
    else { return 0 }

    while sessions.count < count, let session = try? factory.make() {
      sessions.append(session)
      guard encodes(session, frame.pixelBuffer) else { return sessions.count - 1 }
    }
    return sessions.count
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
