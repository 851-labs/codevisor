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
    let profile = try ScreenSharingDiagnosticProfile.process()
    try ScreenSharingFieldTrials.process.install(profile: profile)
    let metrics = ScreenSharingMetrics()
    metrics.label("diagnosticProfileRequested", profile?.name ?? "none")
    metrics.label("diagnosticProfileActive", profile?.name ?? "none")
    if let profile {
      metrics.label(
        "diagnosticProfileRenderer",
        "arrival rendering, \(profile.maximumDrawableCount) drawables, off-main preparation")
    }
    return try await ScreenSharingReceiver(
      configuration: .init(), metrics: metrics, connectivity: connectivity?.native())
  }
}
