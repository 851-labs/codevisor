import CoreVideo
import Foundation
import Testing

@testable import ScreenSharing

extension HardwareCodecTests {
  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingColourFidelityTests {
    static let colours: [(r: Int, g: Int, b: Int)] = [(0, 150, 255), (128, 128, 128), (200, 0, 0), (200, 0, 160)]

    static let hasMain444: Bool = {
      guard
        let configuration = try? ScreenSharingVideoConfiguration(
          width: 320, height: 192, framesPerSecond: 30, bitrate: 8_000_000),
        let encoder = try? ScreenSharingEncoder(
          configuration: configuration, metrics: ScreenSharingMetrics(), useLowLatencyRateControl: false,
          codec: .hevc444)
      else { return false }
      encoder.stop()
      return true
    }()

    @Test(.enabled(if: hasMain444, "No hardware HEVC Main444 encoder on this machine."))
    func flatColoursSurviveTheMain444RoundTrip() async throws {
      let metrics = ScreenSharingMetrics()
      let configuration = try ScreenSharingVideoConfiguration(
        width: 320, height: 192, framesPerSecond: 30, bitrate: 8_000_000)
      let encoder = try ScreenSharingEncoder(
        configuration: configuration, metrics: metrics, useLowLatencyRateControl: false, codec: .hevc444)
      let encoded = CodecOutputLog<ScreenSharingEncodedFrame>()
      encoded.follow(encoder)
      let decoded = CodecOutputLog<ScreenSharingVideoFrame>()
      let decoder = ScreenSharingDecoder(metrics: metrics, codec: .hevc444) { decoded.record($0) }
      defer {
        encoder.stop()
        decoder.stop()
      }
      let picture = try Self.bands(width: 320, height: 192)
      for index in 0..<4 {
        let frame = ScreenSharingVideoFrame(pixelBuffer: picture, timestampNs: Int64(index) * 33_333_333)
        let output = try #require(try await encoded.nextItem { try #require(try encoder.encode(frame)) })
        _ = try #require(try await decoded.nextItem { try decoder.decode(output) })
      }
      let output = try #require(decoded.items.last).pixelBuffer
      for (index, colour) in Self.colours.enumerated() {
        let rgb = Self.rgb(output, x: index * 80 + 40, y: 96)
        print("colour \(colour) -> \(rgb)")
        #expect(
          abs(rgb.r - colour.r) <= 2 && abs(rgb.g - colour.g) <= 2 && abs(rgb.b - colour.b) <= 2, "\(colour) -> \(rgb)")
      }
    }

    @Test func bgraFramesIntoHEVCMainComeOutAsMain() async throws {
      let metrics = ScreenSharingMetrics()
      let configuration = try ScreenSharingVideoConfiguration(
        width: 320, height: 192, framesPerSecond: 30, bitrate: 4_000_000)
      let encoder = try ScreenSharingEncoder(configuration: configuration, metrics: metrics, codec: .hevc)
      let encoded = CodecOutputLog<ScreenSharingEncodedFrame>()
      encoded.follow(encoder)
      let decoded = CodecOutputLog<ScreenSharingVideoFrame>()
      let decoder = ScreenSharingDecoder(metrics: metrics, codec: .hevc) { decoded.record($0) }
      defer {
        encoder.stop()
        decoder.stop()
      }
      let frame = ScreenSharingVideoFrame(pixelBuffer: try Self.bands(width: 320, height: 192), timestampNs: 0)
      let output = try #require(try await encoded.nextItem { try #require(try encoder.encode(frame)) })
      _ = try #require(try await decoded.nextItem { try decoder.decode(output) })
      let labels = metrics.snapshot().labels
      print("bgra->hevc labels:", labels.filter { $0.key.contains("encoded") || $0.key.contains("decoded") })
      #expect(labels["encodedChroma"] == "4:2:0" && labels["encodedHEVCProfileIDC"] == "1")
      #expect(metrics.snapshot().counters["encodeErrors"] == nil && metrics.snapshot().counters["decodeErrors"] == nil)
    }

    @Test func aDecoderMadeForMain444DecodesAMainStream() async throws {
      let metrics = ScreenSharingMetrics()
      let configuration = try ScreenSharingVideoConfiguration(
        width: 320, height: 192, framesPerSecond: 30, bitrate: 4_000_000)
      let encoder = try ScreenSharingEncoder(configuration: configuration, metrics: metrics, codec: .hevc)
      let encoded = CodecOutputLog<ScreenSharingEncodedFrame>()
      encoded.follow(encoder)
      let decoded = CodecOutputLog<ScreenSharingVideoFrame>()
      let decoder = ScreenSharingDecoder(metrics: metrics, codec: .hevc444) { decoded.record($0) }
      defer {
        encoder.stop()
        decoder.stop()
      }
      let source = ScreenSharingVideoFrame(pixelBuffer: try Self.bands(width: 320, height: 192), timestampNs: 0)
      let output = try #require(try await encoded.nextItem { try #require(try encoder.encode(source)) })
      let frame = try #require(try await decoded.nextItem { try decoder.decode(output) })
      #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == ScreenSharingVideoCodec.hevc.decodedPixelFormat)
      #expect(metrics.snapshot().labels["decodedChroma"] == "4:2:0")
      #expect(metrics.snapshot().labels["decoderError"] == nil)
    }

    static func bands(width: Int, height: Int) throws -> CVPixelBuffer {
      var created: CVPixelBuffer?
      let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
      _ = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
      let buffer = try #require(created)
      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      for row in 0..<height {
        for column in 0..<width {
          let colour = colours[column / (width / colours.count)]
          let pixel = base + row * stride + column * 4
          pixel[0] = UInt8(colour.b); pixel[1] = UInt8(colour.g); pixel[2] = UInt8(colour.r); pixel[3] = 255
        }
      }
      CVBufferSetAttachment(
        buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(
        buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
      return buffer
    }

    static func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let format = CVPixelBufferGetPixelFormatType(buffer)
      let fullRange = format == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
      let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
      let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
      var luma = Double(yPlane[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x]) / 255
      let uvIndex = y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x * 2
      var u = Double(uvPlane[uvIndex]) / 255 - 128.0 / 255, v = Double(uvPlane[uvIndex + 1]) / 255 - 128.0 / 255
      if !fullRange {
        luma = (luma - 16.0 / 255) * (255.0 / 219)
        u *= 255.0 / 224; v *= 255.0 / 224
      }
      func level(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
      return (level(luma + 1.5748 * v), level(luma - 0.187324 * u - 0.468124 * v), level(luma + 1.8556 * u))
    }
  }
}
