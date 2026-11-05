import CodevisorTestSupport
import VideoToolbox

@testable import ScreenSharingV2

extension HardwareEncoderBudget {
  static let sessionsPerVCPTile = 2

  static func require(vcpTiles: Int = 0, videoToolboxTiles: Int = 0) async throws {
    try await require(sessions: vcpTiles * sessionsPerVCPTile + videoToolboxTiles) { width, height in
      try? ScreenSharingVideoToolboxSessionFactory(
        width: width, height: height, framesPerSecond: 60, bitrate: 1_000_000
      ).make()
    }
  }
}
