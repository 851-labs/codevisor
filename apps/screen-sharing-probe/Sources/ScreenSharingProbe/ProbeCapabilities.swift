import Foundation
import VideoToolbox

/// Capability discovery is deliberately separate from a measured round trip.
/// An advertised HEVC encoder does not establish negotiated HEVC or 4:4:4 support.
struct ProbeCapabilities: Encodable {
  struct Codec: Encodable {
    let name: String
    let hardwareDecodeAdvertised: Bool
    let encoders: [Encoder]
  }
  struct Encoder: Encodable {
    let identifier: String
    let hardwareAdvertised: Bool?
  }
  let operatingSystem: String
  let negotiatedProbeCodec = "H.264 constrained baseline, 8-bit 4:2:0 SDR"
  let codecs: [Codec]

  static func read() throws -> Self {
    var encoders: CFArray?
    let status = VTCopyVideoEncoderList(nil, &encoders)
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    let entries = encoders as? [[CFString: Any]] ?? []
    let codecs = [("H.264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC)].map { name, type in
      Codec(
        name: name, hardwareDecodeAdvertised: VTIsHardwareDecodeSupported(type),
        encoders: entries.compactMap {
          guard ($0[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value == type else { return nil }
          return Encoder(
            identifier: $0[kVTVideoEncoderList_EncoderID] as? String ?? "unknown",
            hardwareAdvertised: $0[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool)
        })
    }
    return Self(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, codecs: codecs)
  }
}
