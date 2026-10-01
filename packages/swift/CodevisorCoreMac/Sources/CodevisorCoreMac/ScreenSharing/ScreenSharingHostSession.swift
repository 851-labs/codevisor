import AppKit
import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingWebRTC

/// Capture, peer, and media subscriptions belonging to one authorized host session.
@MainActor
final class ScreenSharingHostSession {
  let owner: ScreenSharingHostLease.Owner
  let peer: ScreenSharingSender
  let capture: ScreenSharingCapture
  /// The explicit experimental profile in force for this process, or nil when it is OFF (the default).
  let profile: ScreenSharingDiagnosticProfile?
  let metrics: ScreenSharingMetrics
  let display: ServerScreenSharingDisplay
  /// The shared physical display. macOS can renumber it when the display set changes, so it's
  /// followed by `displayIdentity` (see `followDisplay`).
  var displayID: UInt32
  let displayIdentity: ScreenSharingDisplayIdentity
  /// The physical display scaled to ≤1080p; a virtual display sized to the viewer replaces it
  /// while Dynamic Resolution is on (851-2376).
  var configuration: ScreenSharingVideoConfiguration
  let physicalConfiguration: ScreenSharingVideoConfiguration
  var virtualDisplay: ScreenSharingHostVirtualDisplay?
  var captureDisplayID: UInt32 { virtualDisplay?.displayID ?? displayID }
  /// Posts input within the shared display's current bounds (they change while mirrored).
  var injector: ScreenSharingInputInjector?
  var pendingResize: Task<Void, Never>?
  /// What the capture is running with: the display and configuration it last started or updated to.
  var capturing: (display: CGDirectDisplayID, configuration: ScreenSharingVideoConfiguration)?
  /// The resize being applied; a newer size waits for it rather than cancelling it.
  var resizing: Task<Void, Never>?
  /// Until this uptime, display changes are the host's own (a virtual display appearing,
  /// mirroring, resizing) and don't end the session.
  var ownDisplayChangeUntil: TimeInterval = 0
  var state = "connecting"
  /// What the viewer should show while there's no video, sent with the heartbeat's status
  /// (older viewers ignore it): a stalled capture being recovered (851-2385).
  var notice: String?
  /// Held from the first captured frame's session start until the session ends (851-2375).
  var displaySleepAssertion: ScreenSharingDisplaySleepAssertion?
  var captureRestarts = ScreenSharingCaptureRestartPolicy()
  /// Owns the pointer subscription (851-2377).
  private var cursorStream: ScreenSharingHostCursorStream?
  /// Owns the host audio subscription (851-2379).
  private var audioStream: ScreenSharingHostAudioStream?
  var control: ScreenSharingHostControl?
  /// The codec the answer settled on; its capture format decides whether HDR is possible (851-2380).
  var codec: ScreenSharingVideoCodec?
  /// HDR: what the viewer's screen can show, the switch in progress, what the viewer was told.
  var hdr = ScreenSharingHostService.DynamicRangeState()
  var clipboard: ScreenSharingClipboardTransfer?
  var stopping = false
  var watchdog: Task<Void, Never>?
  var captureTask: Task<Void, Never>?
  var qualityTask: Task<Void, Never>?

  init(
    request: ServerScreenSharingRequest, display: ServerScreenSharingDisplay, displayID: UInt32,
    connectivity: ServerScreenSharingConnectivity, profile: ScreenSharingDiagnosticProfile?
  ) throws {
    owner = .init(request)
    self.profile = profile
    self.display = display; self.displayID = displayID
    displayIdentity = ScreenSharingDisplayIdentity(display: displayID)
    // Level 0 is where a session starts; lower levels request the video rate through the same validated path.
    capture = ScreenSharingCapture(captureIntervalFPS: profile?.captureIntervalFPS(adaptiveLevel: 0))
    let scale = min(1, min(1920.0 / Double(display.width), 1080.0 / Double(display.height)))
    configuration = try ScreenSharingVideoConfiguration(
      width: max(64, Int(Double(display.width) * scale) / 2 * 2),
      height: max(64, Int(Double(display.height) * scale) / 2 * 2),
      bitrate: ScreenSharingHostService.bitrateCeiling)
    physicalConfiguration = configuration
    metrics = ScreenSharingMetrics()
    // install(profile:) throws unless the process trial map equals what this profile requires, so reaching the next
    // line means the profile's settings below are the ones actually wired. "Active" therefore names THIS validated
    // profile; the first installer's provenance is a separate fact published by the peer as fieldTrialProvenance.
    try ScreenSharingFieldTrials.process.install(profile: profile)
    metrics.label("diagnosticProfileRequested", profile?.name ?? "none")
    metrics.label("diagnosticProfileActive", profile?.name ?? "none")
    if let profile {
      metrics.label(
        "diagnosticProfileCaptureRequest",
        "\(profile.captureIntervalFPSAtLevel0) fps at adaptive level 0, video rate below")
    }
    peer = try ScreenSharingSender(
      configuration: configuration, metrics: metrics, connectivity: connectivity.native())
  }

  /// Whether the capture has handed frames to the sender: the viewer has live video to control.
  var hasSentVideo: Bool { metrics.counter("capturedFrames") > 0 }

  func configureMediaSubscriptions() {
    self.cursorStream = ScreenSharingHostCursorStream(
      channel: self.peer.cursorChannel, displayID: self.displayID, metrics: self.metrics,
      isStopping: { [weak self] in self?.stopping ?? true },
      setShowsCursor: { [weak self] showsCursor in
        guard let self else { return }
        Task { try? await self.capture.setShowsCursor(showsCursor) }
      })
    self.audioStream = ScreenSharingHostAudioStream(
      channel: self.peer.audioChannel, tap: self.capture.audio, metrics: self.metrics,
      isStopping: { [weak self] in self?.stopping ?? true },
      setCapturesAudio: { [weak self] capturesAudio in
        guard let self else { return }
        Task { try? await self.capture.setCapturesAudio(capturesAudio) }
      })
  }

  func stopMediaPublishing() {
    cursorStream?.stopPublishing()
    audioStream?.detachCapture()
  }
}
