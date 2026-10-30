import CoreMedia

enum EncodeLabChromaFormat {
  static let hevcChromaByte = 16

  static func of(_ sample: CMSampleBuffer?) -> String? {
    guard let sample, let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
    guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC else { return "4:2:0" }

    let atoms = CMFormatDescriptionGetExtension(
      format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
    guard let record = atoms?["hvcC"] as? Data, record.count > hevcChromaByte else { return nil }

    return name(record[record.startIndex + hevcChromaByte] & 0x03)
  }

  private static func name(_ idc: UInt8) -> String {
    switch idc {
    case 0: "4:0:0"
    case 1: "4:2:0"
    case 2: "4:2:2"
    default: "4:4:4"
    }
  }
}
