import CoreMedia
import CoreVideo
import Foundation

struct VCPLevelsCommand: BenchCommand {
  static let name = "vcp-levels"
  static let summary = "Report the patches VCP's capture, converter, encoder, decoder and viewer shader change"
  static let usage = "[--passes 5] [--no-capture]"

  private let passes: Int
  private let captures: Bool

  init(options: BenchOptions) throws {
    passes = try options.integer("passes", default: 5, in: 1...20)
    captures = try !options.flag("no-capture")
  }

  var presentsWindows: Bool { captures }

  func run() async throws {
    let bgra = try VCPLevelsRamp.bgra()
    let inputs: [(String, CVPixelBuffer)] = [
      ("BGRA through the engine's converter", bgra),
      ("444f converted on the CPU, tagged like the session", try VCPLevelsRamp.fullRange444(tagged: true)),
      ("444f converted on the CPU, untagged", try VCPLevelsRamp.fullRange444(tagged: false)),
    ]
    let renderer = try VCPLevelsRenderer()
    var variants: [VCPLevelsVariant] = []
    for (name, picture) in inputs {
      variants.append(try await variant(name, picture: picture, renderer: renderer))
    }
    try BenchOutput.print(
      VCPLevelsReport(
        machine: BenchHostName.current, captures: captures ? await VCPLevelsCapture.stages(showing: bgra) : [],
        conversions: try pixelTransfers(bgra), variants: variants))
  }

  private func variant(
    _ name: String, picture: CVPixelBuffer, renderer: VCPLevelsRenderer
  ) async throws -> VCPLevelsVariant {
    let units = try await VCPLevelsEncoding.accessUnits(of: picture, passes: passes)
    let decoded = try VCPLevelsDecoder.decode(units, to: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
    let decodedBGRA = try VCPLevelsDecoder.decode(units, to: kCVPixelFormatType_32BGRA)
    return VCPLevelsVariant(
      input: name, accessUnits: units.count, stream: Self.extensions(of: decoded.format),
      stages: [
        VCPLevelsStage(
          "decoded to 444f", values: VCPLevelsRamp.values(of: decoded.image), expecting: .fullRange,
          tags: VCPLevelsTags.of(decoded.image)),
        VCPLevelsStage(
          "viewer shader on the 444f decode", values: try renderer.values(of: decoded.image),
          expecting: .fullRangeRoundTrip),
        VCPLevelsStage(
          "decoded to BGRA by the decoder", values: VCPLevelsRamp.values(of: decodedBGRA.image),
          expecting: .fullRangeRoundTrip,
          tags: VCPLevelsTags.of(decodedBGRA.image)),
      ])
  }

  private func pixelTransfers(_ bgra: CVPixelBuffer) throws -> [VCPLevelsStage] {
    try [
      (kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, "444f", VCPLevelsExpectation.fullRange),
      (kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, "444v", .videoRange),
    ].map { format, name, expectation in
      let converted = try EncodeLabPixelTransfer(
        width: VCPLevelsRamp.width, height: VCPLevelsRamp.height, format: format
      ).transfer(bgra)
      return VCPLevelsStage(
        "VTPixelTransfer BGRA to \(name)", values: VCPLevelsRamp.values(of: converted), expecting: expectation,
        tags: VCPLevelsTags.of(converted))
    }
  }

  private static func extensions(of format: CMVideoFormatDescription) -> [String: String] {
    let keys: [(String, CFString)] = [
      ("full_range", kCMFormatDescriptionExtension_FullRangeVideo),
      ("primaries", kCMFormatDescriptionExtension_ColorPrimaries),
      ("transfer", kCMFormatDescriptionExtension_TransferFunction),
      ("matrix", kCMFormatDescriptionExtension_YCbCrMatrix),
    ]
    var values: [String: String] = [:]
    for (name, key) in keys {
      if let value = CMFormatDescriptionGetExtension(format, extensionKey: key) { values[name] = "\(value)" }
    }
    return values
  }
}
