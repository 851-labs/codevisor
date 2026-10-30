import CoreMedia
import CoreVideo

struct EncodeLabDecodedScreen {
  let config: EncodeLabConfig
  private var decoders: [Int: EncodeLabDecoder] = [:]
  private var latest: [Int: CVPixelBuffer] = [:]

  init(config: EncodeLabConfig) {
    self.config = config
  }

  mutating func decode(_ outputs: [EncodeLabTileOutput]) throws {
    for output in outputs {
      guard let sample = output.sample else { continue }

      latest[output.tile] = try decoder(output.tile, sample).decode(sample)
    }
  }

  var singleImage: CVPixelBuffer? { config.tiles == 1 ? latest[0] : nil }

  func compare(
    with original: CVPixelBuffer, event: EncodeLabFrameEvent, native: EncodeLabNativeQuality?
  ) throws -> EncodeLabQualitySample {
    var reference = EncodeLabPicture(width: config.width, height: config.height)
    reference.paste(original, atRow: 0)
    var shown = EncodeLabPicture(width: config.width, height: config.height)
    for (tile, image) in latest { shown.paste(image, atRow: tile * config.tileHeight) }
    return EncodeLabQualitySample(
      frame: event.frame, version: event.version,
      psnrY: EncodeLabSimilarity.psnr(reference.luma, shown.luma),
      psnrCbCr: EncodeLabSimilarity.psnr([reference.blue, reference.red], [shown.blue, shown.red]),
      ssimY: try EncodeLabSimilarity.ssim(reference.luma, shown.luma, width: config.width, height: config.height),
      native: native, refresh: event.refresh != nil)
  }

  private mutating func decoder(_ tile: Int, _ sample: CMSampleBuffer) throws -> EncodeLabDecoder {
    if let decoder = decoders[tile] { return decoder }

    guard let format = CMSampleBufferGetFormatDescription(sample) else { throw EncodeLabError.decoder("format", -1) }

    let decoder = try EncodeLabDecoder(format: format, output: outputFormat)
    decoders[tile] = decoder
    return decoder
  }

  private var outputFormat: OSType {
    config.codec == .hevc444
      ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
}
