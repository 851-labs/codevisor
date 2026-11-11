import AppKit
import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingV2

@MainActor
final class ScreenSharingHostSession {
  let owner: ScreenSharingHostLease.Owner
  let peer: ScreenSharingV2HostLink
  let v2: V2
  var mediaAccept: Task<Void, Never>?
  let capture: ScreenSharingCapture
  let metrics: ScreenSharingMetrics
  let display: ServerScreenSharingDisplay
  var displayID: UInt32 {
    get { sharedDisplay.displayID }
    set { sharedDisplay.displayID = newValue }
  }
  let displayIdentity: ScreenSharingDisplayIdentity
  var configuration: ScreenSharingVideoConfiguration
  let physicalConfiguration: ScreenSharingVideoConfiguration
  var virtualDisplay: ScreenSharingHostVirtualDisplay?
  var captureDisplayID: UInt32 { virtualDisplay?.displayID ?? displayID }
  let sharedDisplay: ScreenSharingSharedDisplay
  let injector: ScreenSharingInputInjector
  var pendingResize: Task<Void, Never>?
  var capturing: (display: CGDirectDisplayID, configuration: ScreenSharingVideoConfiguration)?
  var resizing: Task<Void, Never>?
  var ownDisplayChangeUntil: TimeInterval = 0
  var state = "connecting"
  var notice: String?
  var displaySleepAssertion: ScreenSharingDisplaySleepAssertion?
  var captureRestarts = ScreenSharingCaptureRestartPolicy()
  private var cursorStream: ScreenSharingHostCursorStream?
  private var audioStream: ScreenSharingHostAudioStream?
  var control: ScreenSharingHostControl?
  var hdr = ScreenSharingHostService.DynamicRangeState()
  var clipboard: ScreenSharingHostClipboard?
  var stopping = false
  var ending: Task<Void, Never>?
  var watchdog: Task<Void, Never>?
  var captureTask: Task<Void, Never>?

  struct V2 {
    let token: String
    let viewerEndpointId: String
  }

  init(
    request: ServerScreenSharingRequest, display: ServerScreenSharingDisplay, displayID: UInt32,
    viewerEndpointId: String, encoder: ScreenSharingV2EncoderKind,
    displayBounds: @escaping @Sendable (CGDirectDisplayID) -> CGRect = { CGDisplayBounds($0) }
  ) throws {
    owner = .init(request)
    self.display = display
    let sharedDisplay = ScreenSharingSharedDisplay(displayID, bounds: displayBounds)
    self.sharedDisplay = sharedDisplay
    injector = ScreenSharingInputInjector(displayBounds: { sharedDisplay.bounds })
    displayIdentity = ScreenSharingDisplayIdentity(display: displayID)
    capture = ScreenSharingCapture()
    metrics = ScreenSharingMetrics()
    configuration = try ScreenSharingV2Profile.captureConfiguration(width: display.width, height: display.height)
    peer = ScreenSharingV2HostLink(configuration: configuration, metrics: metrics) { configuration, metrics in
      try await ScreenSharingV2Encoders.make(encoder, configuration: configuration, metrics: metrics)
    }
    v2 = V2(token: Self.makeToken(), viewerEndpointId: viewerEndpointId)
    physicalConfiguration = configuration
  }

  static func makeToken() -> String {
    (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
  }

  var hasSentVideo: Bool { metrics.counter("capturedFrames") > 0 }

  func configureMediaSubscriptions() {
    self.cursorStream = ScreenSharingHostCursorStream(
      channel: self.peer.channels.cursor, display: self.sharedDisplay, metrics: self.metrics,
      isStopping: { [weak self] in self?.stopping ?? true },
      setShowsCursor: { [weak self] showsCursor in
        guard let self else { return }
        Task { try? await self.capture.setShowsCursor(showsCursor) }
      })
    self.audioStream = ScreenSharingHostAudioStream(
      channel: self.peer.channels.audio, sendPacket: self.peer.sendAudioPacket,
      tap: self.capture.audio, metrics: self.metrics,
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
