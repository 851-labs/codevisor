import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingHEVCFormatTests {
  private func configuration(chroma: UInt8) -> Data {
    var bytes = [UInt8](repeating: 0, count: 23)
    bytes[0] = 1
    bytes[16] = 0xfc | chroma
    return Data(bytes)
  }

  @Test func readsTheChromaFormatFromTheDecoderConfiguration() throws {
    #expect(try ScreenSharingHEVCFormat(configuration: configuration(chroma: 3)).chroma == 3)
    #expect(try ScreenSharingHEVCFormat(configuration: configuration(chroma: 1)).chroma == 1)
  }

  @Test func rejectsTruncationAndUnknownConfigurationVersion() {
    for length in 0..<23 {
      #expect(throws: (any Error).self) {
        try ScreenSharingHEVCFormat(configuration: configuration(chroma: 3).prefix(length))
      }
    }
    var unknown = configuration(chroma: 3)
    unknown[0] = 2
    #expect(throws: (any Error).self) { try ScreenSharingHEVCFormat(configuration: unknown) }
  }
}
