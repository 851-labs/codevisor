import CoreVideo

enum VCPLevelsTags {
  static var session: [(CFString, CFString)] {
    [
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
    ]
  }

  private static var described: [(String, CFString)] {
    [
      ("primaries", kCVImageBufferColorPrimariesKey), ("transfer", kCVImageBufferTransferFunctionKey),
      ("matrix", kCVImageBufferYCbCrMatrixKey),
    ]
  }

  static func of(_ buffer: CVBuffer) -> [String: String] {
    var tags: [String: String] = [:]
    for (name, key) in described {
      if let value = CVBufferCopyAttachment(buffer, key, nil) { tags[name] = "\(value)" }
    }
    return tags
  }
}
