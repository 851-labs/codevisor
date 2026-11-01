import CoreVideo

enum ScreenSharingV2DecodeResult: @unchecked Sendable {
  case decoded(ScreenSharingV2DecodeContext, CVPixelBuffer, decodedNs: Int64)
  case failed(ScreenSharingV2DecodeContext, OSStatus)
}
