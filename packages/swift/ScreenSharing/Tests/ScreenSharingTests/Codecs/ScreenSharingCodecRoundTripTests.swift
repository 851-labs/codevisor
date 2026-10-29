import CodevisorTestSupport
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingCodecRoundTripTests {

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
    #expect(ScreenSharingVideoCodec.hevc444.capturePixelFormat == kCVPixelFormatType_32BGRA)
    #expect(ScreenSharingVideoCodec.hevc444.decodedPixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
    #expect(ScreenSharingVideoCodec(rawValue: "hevc444") == .hevc444)
    #expect(ScreenSharingVideoCodec(rawValue: "vp9") == nil)
  }

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
    let labels = harness.metrics.snapshot().labels
    #expect(labels["encodedChroma"] == "4:4:4" && labels["decodedChroma"] == "4:4:4")
    #expect(labels["encodedBitDepth"] == "8" && labels["decodedBitDepth"] == "8")
    #expect(labels["encodedHEVCProfileIDC"] == "4")
  }

  @Test(.enabled(if: CodecHardware.hasHighDynamicRange, "No hardware HEVC Main 4:4:4 10 encoder on this machine."))
  func hdrFramesKeepTheirTenBitsAndFullChroma() async throws {
    let harness = try CodecHarness(codec: .hevc444, width: 320, height: 192, dynamicRange: .high)
    defer { harness.stop() }
    let decoded = try await harness.decode(harness.encode(index: 0, timestampNs: 0, identity: 7))
    #expect(decoded.pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
    #expect(decoded.sourceTimestampNs == 7)
    #expect(decoded.distinctLumaCodes > 200, "\(decoded.distinctLumaCodes) distinct luma codes")
    let labels = harness.metrics.snapshot().labels
    #expect(labels["encodedChroma"] == "4:4:4" && labels["decodedChroma"] == "4:4:4")
    #expect(labels["encodedBitDepth"] == "10" && labels["decodedBitDepth"] == "10")
    #expect(labels["encodedColor"] == "Display P3 primaries, PQ transfer")
    try harness.restartEncoder(width: 320, height: 192, dynamicRange: .standard)
    let standard = try await harness.decode(harness.encode(index: 1, timestampNs: 33_333_333, identity: 8))
    #expect(standard.pixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
    #expect(harness.metrics.snapshot().counters["decodeErrors"] == nil)
  }

  @Test func dynamicRangeFollowsThePixelFormat() {
    #expect(ScreenSharingDynamicRange(pixelFormat: ScreenSharingDynamicRange.highCapturePixelFormat) == .high)
    #expect(ScreenSharingDynamicRange(pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange) == .high)
    #expect(ScreenSharingDynamicRange(pixelFormat: kCVPixelFormatType_32BGRA) == .standard)
    #expect(ScreenSharingDynamicRange(pixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange) == .standard)
    #expect(ScreenSharingVideoCodec.hevc444.supportsHighDynamicRange)
    #expect(
      !ScreenSharingVideoCodec.hevc.supportsHighDynamicRange && !ScreenSharingVideoCodec.h264.supportsHighDynamicRange)
  }

  @discardableResult
  private func assertRoundTrip(_ codec: ScreenSharingVideoCodec) async throws -> CodecHarness {
    let harness = try CodecHarness(codec: codec, width: 320, height: 192)
    defer { harness.stop() }
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

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func anExplicitRequestProducesAKeyframeOnTheNextEncodeAndIsNotRepeated() async throws {
    let harness = try CodecHarness(codec: .h264, width: 320, height: 192)
    defer { harness.stop() }
    var keyFrames: [Bool] = []
    for index in 0..<4 {
      let encoded = try await harness.encode(
        index: index, timestampNs: Int64(index) * 33_333_333, identity: Int64(index + 1), forceKeyFrame: index == 2)
      keyFrames.append(encoded.isKeyFrame)
      #expect(try await harness.decode(encoded).sourceTimestampNs == Int64(index + 1))
    }
    #expect(keyFrames == [true, false, true, false])
    let counters = harness.metrics.snapshot().counters
    #expect(counters["encoderKeyframeRequests"] == 1 && counters["encoderForcedKeyframesSubmitted"] == 1)
    #expect(counters["encodedKeyFrames"] == 2 && counters["encodedDeltaFrames"] == 2)
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
    #expect(keyFrames == [true, true, true, false])
    let counters = harness.metrics.snapshot().counters
    #expect(counters["encoderKeyframeRequests"] == 2 && counters["encoderForcedKeyframesSubmitted"] == 2)
    #expect(counters["encodedKeyFrames"] == 3 && counters["encodedDeltaFrames"] == 1)
    #expect(counters["encoderRetriedKeyframes"] == nil)
  }

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func theHostStagesRideInBandToTheViewersFrameRecord() async throws {
    let harness = try CodecHarness(codec: .h264, width: 320, height: 192)
    defer { harness.stop() }
    let identity = ScreenSharingMetrics.nowNs - 10_000_000
    let encoded = try await harness.encode(
      index: 0, timestampNs: 0, identity: identity, capturedAtNs: identity + 2_000_000)
    _ = try await harness.decode(encoded)
    harness.metrics.timeline.presented(
      sourceTimestampNs: identity,
      ScreenSharingFramePresentation(receivedAtNs: nil, submittedAtNs: identity, presentedAtNs: identity + 50_000_000))

    let records = harness.metrics.timeline.records(after: 0)
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.stagesUs.capture == 2000)
    #expect((record.stagesUs.hostQueue ?? -1) >= 8000 && (record.stagesUs.encode ?? -1) > 0)
    #expect((record.stagesUs.decode ?? -1) > 0 && record.keyFrame)
    #expect(record.sameClock && record.captureToPresentUs == 50_000)
  }

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func aFrameWithoutACaptureArrivalCarriesNoHostStages() async throws {
    let harness = try CodecHarness(codec: .h264, width: 320, height: 192)
    defer { harness.stop() }
    let decoded = try await harness.decode(harness.encode(index: 0, timestampNs: 0, identity: 5))
    harness.metrics.timeline.presented(
      sourceTimestampNs: 5, ScreenSharingFramePresentation(receivedAtNs: nil, submittedAtNs: 6, presentedAtNs: 7))

    let records = harness.metrics.timeline.records(after: 0)
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(decoded.sourceTimestampNs == 5)
    #expect(record.stagesUs.capture == nil && !record.sameClock && record.captureToPresentUs == nil)
  }

  @Test(.enabled(if: CodecHardware.has(.h264), "No hardware H.264 encoder on this machine."))
  func theDecoderFollowsAMidStreamResolutionChange() async throws {
    let harness = try CodecHarness(codec: .h264, width: 320, height: 192)
    defer { harness.stop() }
    let before = try await harness.decode(harness.encode(index: 0, timestampNs: 0, identity: 1))
    #expect(before.width == 320 && before.height == 192)
    try harness.restartEncoder(width: 256, height: 160)
    let firstAfter = try await harness.encode(index: 0, timestampNs: 33_333_333, identity: 2)
    #expect(firstAfter.isKeyFrame && firstAfter.width == 256 && firstAfter.height == 160)
    let after = try await harness.decode(firstAfter)
    #expect(after.width == 256 && after.height == 160 && after.sourceTimestampNs == 2)
    let continued = try await harness.encode(index: 1, timestampNs: 66_666_666, identity: 3)
    #expect(!continued.isKeyFrame)
    let decoded = try await harness.decode(continued)
    #expect(decoded.width == 256 && decoded.height == 160 && decoded.sourceTimestampNs == 3)
    #expect(harness.metrics.snapshot().counters["decodeErrors"] == nil)
  }
}

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

  static let hasHighDynamicRange: Bool = {
    guard let configuration = try? CodecHarness.configuration(width: 320, height: 192),
      let encoder = try? CodecHarness.makeEncoder(
        codec: .hevc444, configuration: configuration, metrics: ScreenSharingMetrics(), dynamicRange: .high)
    else { return false }
    encoder.stop()
    return true
  }()
}

private final class CodecHarness {
  struct Decoded: Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let timestampNs: Int64
    let sourceTimestampNs: Int64?
    let leftLuma: Double
    let rightLuma: Double
    let distinctLumaCodes: Int
  }

  let codec: ScreenSharingVideoCodec
  let metrics: ScreenSharingMetrics
  private let encoded: EncodedLog
  private let decoded: DecodedLog
  private let decoder: ScreenSharingDecoder
  private var encoder: ScreenSharingEncoder
  private(set) var configuration: ScreenSharingVideoConfiguration
  private(set) var dynamicRange: ScreenSharingDynamicRange

  init(
    codec: ScreenSharingVideoCodec, width: Int, height: Int, dynamicRange: ScreenSharingDynamicRange = .standard
  ) throws {
    let metrics = ScreenSharingMetrics()
    let encoded = EncodedLog()
    let decoded = DecodedLog()
    let configuration = try Self.configuration(width: width, height: height)
    let encoder = try Self.makeEncoder(
      codec: codec, configuration: configuration, metrics: metrics, dynamicRange: dynamicRange)
    encoder.onFrame { encoded.record($0) }
    self.codec = codec
    self.dynamicRange = dynamicRange
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
    codec: ScreenSharingVideoCodec, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    dynamicRange: ScreenSharingDynamicRange = .standard
  ) throws -> ScreenSharingEncoder {
    try ScreenSharingEncoder(
      configuration: configuration, metrics: metrics,
      useLowLatencyRateControl: codec != .hevc444, codec: codec, dynamicRange: dynamicRange)
  }

  func encode(
    index: Int, timestampNs: Int64, identity: Int64, forceKeyFrame: Bool = false, capturedAtNs: Int64? = nil
  ) async throws
    -> ScreenSharingEncodedFrame
  {
    let picture = try Self.picture(
      configuration: configuration,
      format: dynamicRange == .high ? ScreenSharingDynamicRange.highCapturePixelFormat : codec.capturePixelFormat,
      ascending: index.isMultiple(of: 2))
    let target = encoded.count + 1
    let admitted = try encoder.encode(
      ScreenSharingVideoFrame(pixelBuffer: picture, timestampNs: timestampNs, sourceTimestampNs: identity),
      forceKeyFrame: forceKeyFrame, capturedAtNs: capturedAtNs)
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

  func restartEncoder(width: Int, height: Int, dynamicRange: ScreenSharingDynamicRange? = nil) throws {
    encoder.stop()
    configuration = try Self.configuration(width: width, height: height)
    if let dynamicRange { self.dynamicRange = dynamicRange }
    let encoded = encoded
    encoder = try Self.makeEncoder(
      codec: codec, configuration: configuration, metrics: metrics, dynamicRange: self.dynamicRange)
    encoder.onFrame { encoded.record($0) }
  }

  func stop() {
    encoder.stop()
    decoder.stop()
  }

  static func picture(
    configuration: ScreenSharingVideoConfiguration, format: OSType, ascending: Bool
  ) throws
    -> CVPixelBuffer
  {
    var created: CVPixelBuffer?
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
    if format == ScreenSharingDynamicRange.highCapturePixelFormat {
      for plane in 0..<2 {
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        for row in 0..<height {
          let line = UnsafeMutableRawPointer(base + row * stride).assumingMemoryBound(to: UInt16.self)
          for column in 0..<width {
            let code = ascending ? 360 + column : 360 + width - 1 - column
            if plane == 0 {
              line[column] = UInt16(code << 6)
            } else {
              line[column * 2] = 512 << 6
              line[column * 2 + 1] = 512 << 6
            }
          }
        }
      }
      return buffer
    }
    if format == kCVPixelFormatType_32BGRA {
      let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      for row in 0..<height {
        for column in 0..<width {
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

  static func lumaEdges(_ buffer: CVPixelBuffer) -> (left: Double, right: Double, distinct: Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return (0, 0, 0) }
    let tenBit = ScreenSharingDynamicRange(pixelFormat: CVPixelBufferGetPixelFormatType(buffer)) == .high
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    func code(_ row: Int, _ column: Int) -> Int {
      let line = base + row * stride
      return tenBit
        ? Int(line.assumingMemoryBound(to: UInt16.self)[column] >> 6)
        : Int(line.assumingMemoryBound(to: UInt8.self)[column])
    }
    let edge = max(1, width / 8)
    var left = 0
    var right = 0
    for row in 0..<height {
      for column in 0..<edge {
        left += code(row, column)
        right += code(row, width - 1 - column)
      }
    }
    let scale = tenBit ? 4.0 : 1.0
    let distinct = Set((0..<width).map { code(height / 2, $0) }).count
    return (
      Double(left) / Double(height * edge) / scale, Double(right) / Double(height * edge) / scale, distinct
    )
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

  private final class DecodedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Decoded] = []
    let deliveries = TestSignal()

    func record(_ frame: ScreenSharingVideoFrame) {
      let edges = CodecHarness.lumaEdges(frame.pixelBuffer)
      let decoded = Decoded(
        width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
        pixelFormat: CVPixelBufferGetPixelFormatType(frame.pixelBuffer), timestampNs: frame.timestampNs,
        sourceTimestampNs: frame.sourceTimestampNs, leftLuma: edges.left, rightLuma: edges.right,
        distinctLumaCodes: edges.distinct)
      lock.withLock { items.append(decoded) }
      deliveries.signal()
    }

    var frames: [Decoded] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
  }
}
