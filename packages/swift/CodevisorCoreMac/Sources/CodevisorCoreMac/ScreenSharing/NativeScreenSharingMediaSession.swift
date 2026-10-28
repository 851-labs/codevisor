import CodevisorClient
import ScreenSharing
import ScreenSharingWebRTC
import Foundation

@MainActor
protocol NativeScreenSharingMediaSession: ScreenSharingViewingSession {
  func offer() async throws -> String
  func accept(_ answer: String) async throws
}

extension ScreenSharingReceiver: NativeScreenSharingMediaSession {
  func offer() async throws -> String { try await makeDescription(offer: true).sdp }
  func accept(_ answer: String) async throws { try await accept(.init(kind: "answer", sdp: answer)) }

  static func process(connectivity: ServerScreenSharingConnectivity?) async throws -> ScreenSharingReceiver {
    ScreenSharingFieldTrials.process.installProduct()
    return try await ScreenSharingReceiver(
      configuration: .init(), metrics: ScreenSharingMetrics(), connectivity: connectivity?.native())
  }
}
