import CodevisorClient
import ScreenSharing
import ScreenSharingWebRTC
import Foundation

/// A viewing session the native backend can negotiate: the generic contract
/// plus the SDP exchange that only the WebRTC transport has. Tests fake this
/// to drive the backend without media.
@MainActor
protocol NativeScreenSharingMediaSession: ScreenSharingViewingSession {
  func offer() async throws -> String
  func accept(_ answer: String) async throws
}

extension ScreenSharingReceiver: NativeScreenSharingMediaSession {
  func offer() async throws -> String { try await makeDescription(offer: true).sdp }
  func accept(_ answer: String) async throws { try await accept(.init(kind: "answer", sdp: answer)) }

  /// The product receiver for this process: the diagnostic profile is parsed
  /// once per process and its field trials are installed (or proven installed)
  /// BEFORE the peer exists, so both roles in one app process agree. A conflict
  /// with a selection already installed by the host role throws here.
  static func process(connectivity: ServerScreenSharingConnectivity?) throws -> ScreenSharingReceiver {
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
    return try ScreenSharingReceiver(configuration: .init(), metrics: metrics, connectivity: connectivity?.native())
  }
}
