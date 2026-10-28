import AppKit
import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingWebRTC

@MainActor
final class ScreenSharingHostSession {
  let owner: ScreenSharingHostLease.Owner
  let peer: ScreenSharingSender
  let capture: ScreenSharingCapture
  let metrics: ScreenSharingMetrics
  let display: ServerScreenSharingDisplay
  var displayID: UInt32
  let displayIdentity: ScreenSharingDisplayIdentity
  var configuration: ScreenSharingVideoConfiguration
  let physicalConfiguration: ScreenSharingVideoConfiguration
  var virtualDisplay: ScreenSharingHostVirtualDisplay?
  var captureDisplayID: UInt32 { virtualDisplay?.displayID ?? displayID }
  var injector: ScreenSharingInputInjector?
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
  var codec: ScreenSharingVideoCodec?
  var hdr = ScreenSharingHostService.DynamicRangeState()
  var clipboard: ScreenSharingHostClipboard?
  var stopping = false
  var ending: Task<Void, Never>?
  var watchdog: Task<Void, Never>?
  var captureTask: Task<Void, Never>?
  var qualityTask: Task<Void, Never>?

  init(
    request: ServerScreenSharingRequest, display: ServerScreenSharingDisplay, displayID: UInt32,
    connectivity: ServerScreenSharingConnectivity
  ) async throws {
    owner = .init(request)
    self.display = display; self.displayID = displayID
    displayIdentity = ScreenSharingDisplayIdentity(display: displayID)
    capture = ScreenSharingCapture()
    let size = ScreenSharingHostService.physicalCaptureSize(width: display.width, height: display.height)
    configuration = try ScreenSharingVideoConfiguration(
      width: size.width, height: size.height, bitrate: ScreenSharingHostService.bitrateCeiling)
    physicalConfiguration = configuration
    metrics = ScreenSharingMetrics()
    ScreenSharingFieldTrials.process.installProduct()
    peer = try await ScreenSharingSender(
      configuration: configuration, metrics: metrics, connectivity: connectivity.native())
  }

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
      channel: self.peer.audioChannel,
      sendPacket: { [weak audioChannel = self.peer.audioChannel] in audioChannel?.send($0) ?? false },
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
