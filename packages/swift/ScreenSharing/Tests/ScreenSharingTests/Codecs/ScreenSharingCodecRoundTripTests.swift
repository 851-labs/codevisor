import CodevisorTestSupport
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

/// The VideoToolbox pair over synthetic pictures: what the host encoded is what
/// the viewer decodes, at the negotiated size, pixel format, identity and order.
/// Encoder and decoder callbacks arrive on VideoToolbox's own queues, so every
/// wait here is on the delivery signal those callbacks raise. The time limit is
/// a deadlock guard for that hardware boundary, never an expected result: a
/// codec that silently stops delivering must fail the suite rather than hang it.
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingCodecRoundTripTests {

  // MARK: the codec table

  @Test func eachCodecNamesItsMediaTypeCaptureFormatAndDecodedFormat() {
    #expect(ScreenSharingVideoCodec.allCases == [.h264, .hevc, .hevc444])
    #expect(ScreenSharingVideoCodec.h264.mediaType == kCMVideoCodecType_H264)
    #expect(ScreenSharingVideoCodec.hevc.mediaType == kCMVideoCodecType_HEVC)
    #expect(ScreenSharingVideoCodec.hevc444.mediaType == kCMVideoCodecType_HEVC)
    #expect(ScreenSharingVideoCodec.h264.payloadName == "H264")
    #expect(ScreenSharingVideoCodec.hevc.payloadName == "H265" && ScreenSharingVideoCodec.hevc444.payloadName == "H265")
    for codec: ScreenSharingVideoCodec in [.h264, .hevc] {
      #expect(codec.capturePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      #expect(codec.decodedPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    // Only Main444 captures BGRA: subsampling before the encoder would discard
    // the chroma the 4:4:4 profile exists to keep.
    #expect(ScreenSharingVideoCodec.hevc444.capturePixelFormat == kCVPixelFormatType_32BGRA)
    #expect(ScreenSharingVideoCodec.hevc444.decodedPixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
    #expect(ScreenSharingVideoCodec(rawValue: "hevc444") == .hevc444)
    #expect(ScreenSharingVideoCodec(rawValue: "vp9") == nil)
  }

  // MARK: encode to decode

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func h264FramesSurviveTheRoundTripWithTheirIdentityAndOrder() async throws {
    try await assertRoundTrip(.h264)
  }

  @Test(.enabled(if: CodecHardware.has(.hevc), "No hardware HEVC encoder on this machine."))
  func hevcFramesSurviveTheRoundTripWithTheirIdentityAndOrder() async throws {
    try await assertRoundTrip(.hevc)
  }

  @Test(.enabled(if: CodecHardware.has(.hevc444), "No hardware HEVC Main444 encoder on this machine."))
  func hevc444FramesSurviveTheRoundTripAtFullChroma() async throws {
    let harness = try await assertRoundTrip(.hevc444)
    // The 4:4:4 claim is the reason this codec exists: a silent fallback to
    // 4:2:0 or to 10 bits would otherwise decode perfectly well.
    let labels = harness.metrics.snapshot().labels
    #expect(labels["encodedChroma"] == "4:4:4" && labels["decodedChroma"] == "4:4:4")
    #expect(labels["encodedBitDepth"] == "8" && labels["decodedBitDepth"] == "8")
    #expect(labels["encodedHEVCProfileIDC"] == "4")
  }

  @discardableResult
  private func assertRoundTrip(_ codec: ScreenSharingVideoCodec) async throws -> CodecHarness {
    let harness = try CodecHarness(codec: codec, width: 320, height: 192)
    defer { harness.stop() }
    // Identities are deliberately not the presentation timestamps: the viewer
    // reads content identity from the in-band marker, never from frame counting.
    let identities: [Int64] = [1_726_100_000_000_000_001, 1_726_100_000_000_000_002, 1_726_100_000_000_000_003]
    var decoded: [CodecHarness.Decoded] = []
    for (index, identity) in identities.enumerated() {
      let encoded = try await harness.encode(
        index: index, timestampNs: Int64(index) * 33_333_333, identity: identity)
      #expect(encoded.width == 320 && encoded.height == 192)
      #expect(encoded.isKeyFrame == (index == 0))
      #expect(encoded.sourceTimestampNs == identity)
      decoded.append(try await harness.decode(encoded))
    }
    #expect(decoded.map(\.sourceTimestampNs) == identities)
    #expect(decoded.map(\.timestampNs) == [0, 33_333_333, 66_666_666])
    for frame in decoded {
      #expect(frame.width == 320 && frame.height == 192)
      #expect(frame.pixelFormat == codec.decodedPixelFormat)
    }
    // Structure, not pixels: these encoders are lossy and the hardware differs
    // per machine. The source ramp spans the whole video-range luma scale, so
    // the bright edge stays far above the dark one, and the ramp's direction
    // flips with the input's — a stale, blank or reordered output cannot.
    for (index, frame) in decoded.enumerated() {
      let dark = index.isMultiple(of: 2) ? frame.leftLuma : frame.rightLuma
      let bright = index.isMultiple(of: 2) ? frame.rightLuma : frame.leftLuma
      #expect(bright - dark > 100, "frame \(index): left \(frame.leftLuma), right \(frame.rightLuma)")
    }
    let counters = harness.metrics.snapshot().counters
    #expect(counters["encodedFrames"] == 3 && counters["decodedFrames"] == 3)
    #expect(counters["encodeErrors"] == nil && counters["decodeErrors"] == nil)
    #expect(counters["encoderBackpressureDrops"] == nil && counters["encoderDroppedFrames"] == nil)
    return harness
  }

  // MARK: keyframes

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func anExplicitRequestProducesAKeyframeOnTheNextEncodeAndIsNotRepeated() async throws {
    let harness = try CodecHarness(codec: .h264, width: 320, height: 192)
    defer { harness.stop() }
    var keyFrames: [Bool] = []
    for index in 0..<4 {
      // The third frame carries the request; the fourth proves a satisfied
      // request is not still latched.
      let encoded = try await harness.encode(
        index: index, timestampNs: Int64(index) * 33_333_333, identity: Int64(index + 1), forceKeyFrame: index == 2)
      keyFrames.append(encoded.isKeyFrame)
      #expect(try await harness.decode(encoded).sourceTimestampNs == Int64(index + 1))
    }
    #expect(keyFrames == [true, false, true, false])
    let counters = harness.metrics.snapshot().counters
    #expect(counters["encoderKeyframeRequests"] == 1 && counters["encoderForcedKeyframesSubmitted"] == 1)
    #expect(counters["encodedKeyFrames"] == 2 && counters["encodedDeltaFrames"] == 2)
    // One request, one forced output: nothing retried, nothing deferred.
    #expect(counters["encoderRetriedKeyframes"] == nil && counters["encoderDeferredKeyframeRequests"] == nil)
    #expect(counters["decodedKeyFrames"] == 2)
  }

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func consecutiveRequestsEachProduceOneKeyframeAndNoneOutlivesItsFrame() async throws {
    let harness = try CodecHarness(codec: .h264, width: 320, height: 192)
    defer { harness.stop() }
    var keyFrames: [Bool] = []
    for index in 0..<4 {
      let encoded = try await harness.encode(
        index: index, timestampNs: Int64(index) * 33_333_333, identity: Int64(index + 1),
        forceKeyFrame: index == 1 || index == 2)
      keyFrames.append(encoded.isKeyFrame)
    }
    // Two requests, two forced keyframes, and the unrequested frame after them
    // is a delta: a request neither multiplies nor survives its own output.
    #expect(keyFrames == [true, true, true, false])
    let counters = harness.metrics.snapshot().counters
    #expect(counters["encoderKeyframeRequests"] == 2 && counters["encoderForcedKeyframesSubmitted"] == 2)
    #expect(counters["encodedKeyFrames"] == 3 && counters["encodedDeltaFrames"] == 1)
    #expect(counters["encoderRetriedKeyframes"] == nil)
  }

  // MARK: resolution changes

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func theDecoderFollowsAMidStreamResolutionChange() async throws {
    let harness = try CodecHarness(codec: .h264, width: 320, height: 192)
    defer { harness.stop() }
    let before = try await harness.decode(harness.encode(index: 0, timestampNs: 0, identity: 1))
    #expect(before.width == 320 && before.height == 192)
    // The transport restarts the encoder for a new resolution and keeps the
    // decoder: its session is rebuilt from the new keyframe's parameter sets.
    try harness.restartEncoder(width: 256, height: 160)
    let firstAfter = try await harness.encode(index: 0, timestampNs: 33_333_333, identity: 2)
    #expect(firstAfter.isKeyFrame && firstAfter.width == 256 && firstAfter.height == 160)
    let after = try await harness.decode(firstAfter)
    #expect(after.width == 256 && after.height == 160 && after.sourceTimestampNs == 2)
    // The stream continues at the new size, off the new session's keyframe.
    let continued = try await harness.encode(index: 1, timestampNs: 66_666_666, identity: 3)
    #expect(!continued.isKeyFrame)
    let decoded = try await harness.decode(continued)
    #expect(decoded.width == 256 && decoded.height == 160 && decoded.sourceTimestampNs == 3)
    #expect(harness.metrics.snapshot().counters["decodeErrors"] == nil)
  }
}

/// Hardware support differs per machine, and Main444 is absent on many. Creating
/// a real session is the only reliable answer, so probe once per process and
/// gate on the result: an unsupported codec reports a skip with its reason
/// rather than a failure, and a supported one is never quietly passed over.
private enum CodecHardware {
  static let encoders: Set<ScreenSharingVideoCodec> = Set(
    ScreenSharingVideoCodec.allCases.filter { codec in
      guard let configuration = try? CodecHarness.configuration(width: 320, height: 192),
        let encoder = try? CodecHarness.makeEncoder(
          codec: codec, configuration: configuration, metrics: ScreenSharingMetrics())
      else { return false }
      encoder.stop()
      return true
    })

  static func has(_ codec: ScreenSharingVideoCodec) -> Bool { encoders.contains(codec) }
}

/// One encoder feeding one decoder. The logs are the only state shared with
/// VideoToolbox's callback queues; the harness itself stays on the test's task.
private final class CodecHarness {
  struct Decoded: Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let timestampNs: Int64
    let sourceTimestampNs: Int64?
    let leftLuma: Double
    let rightLuma: Double
  }

  let codec: ScreenSharingVideoCodec
  let metrics: ScreenSharingMetrics
  private let encoded: EncodedLog
  private let decoded: DecodedLog
  private let decoder: ScreenSharingDecoder
  private var encoder: ScreenSharingEncoder
  private(set) var configuration: ScreenSharingVideoConfiguration

  init(codec: ScreenSharingVideoCodec, width: Int, height: Int) throws {
    let metrics = ScreenSharingMetrics()
    let encoded = EncodedLog()
    let decoded = DecodedLog()
    let configuration = try Self.configuration(width: width, height: height)
    let encoder = try Self.makeEncoder(codec: codec, configuration: configuration, metrics: metrics)
    encoder.onFrame { encoded.record($0) }
    self.codec = codec
    self.metrics = metrics
    self.encoded = encoded
    self.decoded = decoded
    self.configuration = configuration
    self.encoder = encoder
    decoder = ScreenSharingDecoder(metrics: metrics, codec: codec) { decoded.record($0) }
  }

  static func configuration(width: Int, height: Int) throws -> ScreenSharingVideoConfiguration {
    try ScreenSharingVideoConfiguration(width: width, height: height, framesPerSecond: 30, bitrate: 4_000_000)
  }

  static func makeEncoder(
    codec: ScreenSharingVideoCodec, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) throws -> ScreenSharingEncoder {
    try ScreenSharingEncoder(
      configuration: configuration, metrics: metrics,
      // Main444 refuses the low-latency rate control, which can reduce chroma.
      useLowLatencyRateControl: codec != .hevc444, codec: codec)
  }

  /// Submits one picture and returns the frame the encoder's callback delivered.
  /// Awaiting each output keeps admission, and so the whole run, free of any
  /// dependence on VideoToolbox's completion timing.
  func encode(
    index: Int, timestampNs: Int64, identity: Int64, forceKeyFrame: Bool = false
  ) async throws
    -> ScreenSharingEncodedFrame
  {
    let picture = try Self.picture(
      configuration: configuration, format: codec.capturePixelFormat, ascending: index.isMultiple(of: 2))
    let target = encoded.count + 1
    let admitted = try encoder.encode(
      ScreenSharingVideoFrame(pixelBuffer: picture, timestampNs: timestampNs, sourceTimestampNs: identity),
      forceKeyFrame: forceKeyFrame)
    #expect(admitted)
    await encoded.deliveries.wait(for: target)
    return encoded.frames[target - 1]
  }

  func decode(_ frame: ScreenSharingEncodedFrame) async throws -> Decoded {
    let target = decoded.count + 1
    try decoder.decode(frame)
    await decoded.deliveries.wait(for: target)
    return decoded.frames[target - 1]
  }

  /// WebRTC restarts the encoder for a new resolution and keeps the decoder.
  func restartEncoder(width: Int, height: Int) throws {
    encoder.stop()
    configuration = try Self.configuration(width: width, height: height)
    let encoded = encoded
    encoder = try Self.makeEncoder(codec: codec, configuration: configuration, metrics: metrics)
    encoder.onFrame { encoded.record($0) }
  }

  /// Both sessions drain their callbacks before returning, so no output can
  /// arrive after a test has finished with the harness.
  func stop() {
    encoder.stop()
    decoder.stop()
  }

  /// A horizontal luma ramp over the full video range, reversed on alternate
  /// frames so a decoded picture can be matched to the input that produced it.
  static func picture(
    configuration: ScreenSharingVideoConfiguration, format: OSType, ascending: Bool
  ) throws
    -> CVPixelBuffer
  {
    var created: CVPixelBuffer?
    // IOSurface backing is what makes the buffer usable by the hardware encoder.
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    #expect(
      CVPixelBufferCreate(nil, configuration.width, configuration.height, format, attributes, &created)
        == kCVReturnSuccess)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = configuration.width
    let height = configuration.height
    func level(_ column: Int) -> Int { (ascending ? column : width - 1 - column) * 255 / (width - 1) }
    if format == kCVPixelFormatType_32BGRA {
      let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      for row in 0..<height {
        for column in 0..<width {
          // Neutral grey, so BT.709 luma tracks the ramp exactly.
          let pixel = base + row * stride + column * 4
          let value = UInt8(level(column))
          pixel[0] = value
          pixel[1] = value
          pixel[2] = value
          pixel[3] = 255
        }
      }
      return buffer
    }
    let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for row in 0..<height {
      for column in 0..<width { (luma + row * lumaStride)[column] = UInt8(16 + 219 * level(column) / 255) }
    }
    let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
      for column in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) { (chroma + row * chromaStride)[column] = 128 }
    }
    return buffer
  }

  /// Mean luma of the outer eighth of each side of the picture.
  static func lumaEdges(_ buffer: CVPixelBuffer) -> (left: Double, right: Double) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return (0, 0) }
    let luma = base.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let edge = max(1, width / 8)
    var left = 0
    var right = 0
    for row in 0..<height {
      let line = luma + row * stride
      for column in 0..<edge {
        left += Int(line[column])
        right += Int(line[width - 1 - column])
      }
    }
    return (Double(left) / Double(height * edge), Double(right) / Double(height * edge))
  }

  private final class EncodedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScreenSharingEncodedFrame] = []
    let deliveries = TestSignal()

    func record(_ frame: ScreenSharingEncodedFrame) {
      lock.withLock { items.append(frame) }
      deliveries.signal()
    }

    var frames: [ScreenSharingEncodedFrame] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
  }

  /// The decoded buffer is measured inside the callback: its pool can recycle
  /// the storage once the frame is released, so nothing is read afterwards.
  private final class DecodedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Decoded] = []
    let deliveries = TestSignal()

    func record(_ frame: ScreenSharingVideoFrame) {
      let edges = CodecHarness.lumaEdges(frame.pixelBuffer)
      let decoded = Decoded(
        width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
        pixelFormat: CVPixelBufferGetPixelFormatType(frame.pixelBuffer), timestampNs: frame.timestampNs,
        sourceTimestampNs: frame.sourceTimestampNs, leftLuma: edges.left, rightLuma: edges.right)
      lock.withLock { items.append(decoded) }
      deliveries.signal()
    }

    var frames: [Decoded] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
  }
}
