import CoreMedia
import VideoToolbox

struct EncodeLabVCPSessionFactory {
  static let tilesKey = "NumberOfTiles"
  static let realTimeKey = "RealTime"
  static let callback: VTCompressionOutputCallback = { refcon, frameRefcon, _, _, sample in
    guard let refcon else { return }

    Unmanaged<EncodeLabVCPEncoder>.fromOpaque(refcon).takeUnretainedValue()
      .record(frameRefcon: frameRefcon, sample: sample)
  }

  let api: EncodeLabVideoProcessing
  let config: EncodeLabConfig

  func make(refcon: Unmanaged<EncodeLabVCPEncoder>) throws -> AnyObject {
    let session = try create(refcon: refcon)
    do {
      try EncodeLabSessionProperties(config: config, target: EncodeLabVCPPropertyTarget(api: api, session: session))
        .apply()
      return session
    } catch {
      api.invalidate(session)
      throw error
    }
  }

  private func create(refcon: Unmanaged<EncodeLabVCPEncoder>) throws -> AnyObject {
    var created: Unmanaged<AnyObject>?
    let status = api.create(
      kCFAllocatorDefault, Int32(config.width), Int32(config.height), kCMVideoCodecType_HEVC,
      specification as CFDictionary, sourceAttributes as CFDictionary, nil, Self.callback, refcon.toOpaque(), &created)
    guard status == noErr, let session = created?.takeRetainedValue() else {
      throw EncodeLabError.encoder("create VCP", status)
    }

    return session
  }

  private var sourceAttributes: [CFString: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey: config.vcpInputFormat, kCVPixelBufferWidthKey: config.width,
      kCVPixelBufferHeightKey: config.height, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
  }

  private var specification: [CFString: Any] {
    [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
      api.usageKey: EncodeLabVideoProcessing.usage,
      Self.realTimeKey as CFString: true, Self.tilesKey as CFString: config.tiles,
      kVTCompressionPropertyKey_ProfileLevel: EncodeLabVCPPropertyTarget.main444,
    ]
  }
}
