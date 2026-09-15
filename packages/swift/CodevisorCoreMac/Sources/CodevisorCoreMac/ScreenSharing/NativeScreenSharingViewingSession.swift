import CodevisorClient
import CodevisorScreenSharing
import Foundation

/// A viewing session the native backend can negotiate: the generic contract
/// plus the SDP exchange that only the WebRTC transport has. Tests fake this
/// to drive the backend without media.
@MainActor
protocol NativeScreenSharingMediaSession: ScreenSharingViewingSession {
  func offer() async throws -> String
  func accept(_ answer: String) async throws
}

/// The WebRTC-backed viewing session: one receive-only peer, its negotiated
/// control and clipboard channels, and its decoded-frame mailbox.
@MainActor
final class NativeScreenSharingViewingSession: NativeScreenSharingMediaSession {
  let peer: ScreenSharingPeer
  let capabilities: ScreenSharingCapabilities = [.control, .clipboard, .statistics]
  var frames: ScreenSharingFrameMailbox { peer.mailbox }
  var metrics: ScreenSharingMetrics { peer.metrics }
  let control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)?
  let clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)?
  var failure: String? { peer.metrics.snapshot().labels["decoderError"] }
  var onConnectionChanged: ((String) -> Void)? {
    get { peer.onConnectionChanged }
    set { peer.onConnectionChanged = newValue }
  }

  init(connectivity: ServerScreenSharingConnectivity?, metrics: ScreenSharingMetrics) throws {
    peer = try ScreenSharingPeer(
      sending: false, configuration: .init(), metrics: metrics, connectivity: connectivity?.native())
    control = peer.control
    clipboard = peer.clipboard
  }

  /// The product session for this process: the diagnostic profile is parsed
  /// once per process and its field trials are installed (or proven installed)
  /// BEFORE the peer exists, so both roles in one app process agree. A conflict
  /// with a selection already installed by the host role throws here.
  static func process(connectivity: ServerScreenSharingConnectivity?) throws -> NativeScreenSharingViewingSession {
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
    return try NativeScreenSharingViewingSession(connectivity: connectivity, metrics: metrics)
  }

  func offer() async throws -> String { try await peer.makeDescription(offer: true).sdp }
  func accept(_ answer: String) async throws { try await peer.accept(.init(kind: "answer", sdp: answer)) }
  func statistics() async -> [String: String] { await peer.statistics() }
  func close() { peer.close() }
}
