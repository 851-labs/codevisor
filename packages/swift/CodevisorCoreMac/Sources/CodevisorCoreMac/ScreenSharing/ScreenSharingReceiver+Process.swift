import CodevisorClient
import ScreenSharing
import ScreenSharingWebRTC
import Foundation

extension ScreenSharingReceiver {
  static func process(connectivity: ServerScreenSharingConnectivity?) async throws -> ScreenSharingReceiver {
    try await ScreenSharingReceiver(
      configuration: .init(), metrics: ScreenSharingMetrics(), connectivity: connectivity?.native())
  }
}
