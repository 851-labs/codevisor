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
  let sessionToken = ScreenSharingHostChallenges.randomHex()
  var mediaAccept: Task<Void, Never>?
  let capture: ScreenSharingCapture
  let metrics: ScreenSharingMetrics
  var display: ServerScreenSharingDisplay
  var displays: [ServerScreenSharingDisplay] = []
  var sharesStandIn = false
  var displayID: UInt32 {
    get { sharedDisplay.displayID }
    set { sharedDisplay.displayID = newValue }
  }
  private(set) var displayIdentity: ScreenSharingDisplayIdentity
  var configuration: ScreenSharingVideoConfiguration
  private(set) var physicalConfiguration: ScreenSharingVideoConfiguration
  var displaySwitch: ScreenSharingHostDisplaySwitch?
  var virtualDisplay: ScreenSharingHostVirtualDisplay? {
    didSet { sharedDisplay.virtualDisplayID = virtualDisplay?.displayID }
  }
  var sharedMode: ScreenSharingHostRetina.SharedDisplay
  var dynamicDesktop: (width: Int, height: Int)?
  var captureDisplayID: UInt32 { virtualDisplay?.displayID ?? displayID }
  var virtualDisplayStandsInForShared: Bool {
    guard let virtualDisplay else { return false }
    return (virtualDisplay.replacesShared ? virtualDisplay.displayID : virtualDisplay.shared) == displayID
  }
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
  var captureFailure: String?
  var failure: String? {
    if let captureFailure { return captureFailure }
    guard let encoder = metrics.label("encoderError"), !encoder.isEmpty else { return nil }

    return encoder
  }

  struct V2 {
    let token: String
    let viewerEndpointId: String
  }

  init(
    owner: ScreenSharingHostLease.Owner, request: ServerScreenSharingRequest, display: ServerScreenSharingDisplay,
    displayID: UInt32,
    viewerEndpointId: String, encoder: ScreenSharingV2EncoderKind,
    displayBounds: @escaping @Sendable (CGDirectDisplayID) -> CGRect = { CGDisplayBounds($0) }
  ) throws {
    self.owner = owner
    self.display = display
    let sharedDisplay = ScreenSharingSharedDisplay(displayID, bounds: displayBounds)
    self.sharedDisplay = sharedDisplay
    injector = ScreenSharingInputInjector(displayBounds: { sharedDisplay.bounds })
    displayIdentity = ScreenSharingDisplayIdentity(display: displayID)
    sharedMode = .init(display: displayID)
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

  var hasSentVideo: Bool { metrics.counter(ScreenSharingV2Host.sentFramesMetric) > 0 }

  var awaitsLiveVideo: Bool { stopping || (state != "viewing" && !hasSentVideo) }

  struct Target {
    let displayID: UInt32
    let identity: ScreenSharingDisplayIdentity
    let configuration: ScreenSharingVideoConfiguration
  }

  var target: Target { .init(displayID: displayID, identity: displayIdentity, configuration: physicalConfiguration) }

  static func target(_ display: (id: UInt32, description: ServerScreenSharingDisplay)) throws -> Target {
    let configuration = try ScreenSharingV2Profile.captureConfiguration(
      width: display.description.width, height: display.description.height)
    return .init(displayID: display.id, identity: .init(display: display.id), configuration: configuration)
  }

  func share(_ target: Target) {
    displayID = target.displayID
    displayIdentity = target.identity
    sharedMode = .init(display: target.displayID)
    physicalConfiguration = target.configuration
    configuration = target.configuration
  }

  func hasToken(_ candidate: String) -> Bool {
    ScreenSharingHostChallenges.token(sessionToken, matches: candidate)
  }

  func configureMediaSubscriptions() {
    self.cursorStream = ScreenSharingHostCursorStream(
      channel: self.peer.channels.cursor, display: self.sharedDisplay, metrics: self.metrics,
      isStopping: { [weak self] in self?.stopping ?? true },
      setShowsCursor: { [weak self] showsCursor in
        self?.changeCapture("cursor stream \(showsCursor ? "off" : "on")") { try await $0.setShowsCursor(showsCursor) }
      })
    self.audioStream = ScreenSharingHostAudioStream(
      channel: self.peer.channels.audio, sendPacket: self.peer.sendAudioPacket,
      tap: self.capture.audio, metrics: self.metrics,
      isStopping: { [weak self] in self?.stopping ?? true },
      setCapturesAudio: { [weak self] capturesAudio in
        self?.changeCapture("audio \(capturesAudio ? "on" : "off")") { try await $0.setCapturesAudio(capturesAudio) }
      })
  }

  private func changeCapture(_ what: String, _ change: @escaping @MainActor (ScreenSharingCapture) async throws -> Void)
  {
    Task {
      do {
        try await change(capture)
        ScreenSharingHostService.logger.notice("Capture changed (\(what, privacy: .public))")
      } catch {
        ScreenSharingHostService.logger.error(
          "Capture change failed (\(what, privacy: .public)): \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func stopMediaPublishing() {
    cursorStream?.stopPublishing()
    audioStream?.detachCapture()
  }
}
