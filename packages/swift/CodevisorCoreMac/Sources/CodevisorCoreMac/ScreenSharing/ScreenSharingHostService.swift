import AppKit
import CodevisorCore
import ScreenSharing
import ScreenSharingWebRTC
import Foundation
import OSLog

/// One authorized viewer per native host. Capture starts only after the peer
/// carrying the authenticated SDP connects, and a missed lease stops capture.
@MainActor
final class ScreenSharingHostService {
  /// The sender's ceiling on LAN and Tailscale (the only networks native sharing targets,
  /// 851-2370): room for sharp text and motion; the encoder spends it only when content needs it.
  static let bitrateCeiling = 30_000_000
  /// What 60 fps at the session's resolution needs; the adaptive policy measures shortage
  /// against this, not the ceiling (851-2372).
  static let fullQualityBitrate = 6_000_000
  /// Estimates while the bandwidth estimator ramps up after connecting aren't a shortage.
  static let estimateWarmUp: TimeInterval = 5
  typealias Display = (id: UInt32, description: ServerScreenSharingDisplay)
  static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  @MainActor final class Session {
    let owner: ScreenSharingHostLease.Owner
    let peer: ScreenSharingSender
    let capture: ScreenSharingCapture
    /// The explicit experimental profile in force for this process, or nil when it is OFF (the default).
    let profile: ScreenSharingDiagnosticProfile?
    let metrics: ScreenSharingMetrics
    let display: ServerScreenSharingDisplay
    let displayID: UInt32
    /// The physical display scaled to ≤1080p; a virtual display sized to the viewer replaces it
    /// while Dynamic Resolution is on (851-2376).
    var configuration: ScreenSharingVideoConfiguration
    let physicalConfiguration: ScreenSharingVideoConfiguration
    var virtualDisplay: ScreenSharingHostVirtualDisplay?
    var captureDisplayID: UInt32 { virtualDisplay?.displayID ?? displayID }
    /// Posts input within the shared display's current bounds (they change while mirrored).
    var injector: ScreenSharingInputInjector?
    var pendingResize: Task<Void, Never>?
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
    /// The pointer as its own stream, once the viewer subscribed (851-2377).
    var cursor: ScreenSharingCursorPublisher?
    /// The host's sound, once the viewer subscribed (851-2379).
    var audioEncoder: ScreenSharingAudioEncoder?
    var control: ScreenSharingHostControl?
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
  }
  private var current: Session?
  /// Why the host itself last ended a viewer's session, told to that viewer's next heartbeat: its
  /// connection just drops, and "the connection ended" blamed the network (851-2397).
  private var lastEnd: (owner: ScreenSharingHostLease.Owner, reason: String)?
  // Enumeration can suspend before a session owns the lease. Stop must invalidate those attempts by owner too.
  private var pendingStarts: [UUID: ScreenSharingHostLease.Owner] = [:]
  private var isShutdown = false
  private var stopGeneration = 0
  private var lease = ScreenSharingHostLease()
  private let indicator = ScreenSharingHostIndicator()
  private var observers: [NSObjectProtocol] = []
  private let connectivity = ScreenSharingHostConnectivity(environment: ProcessInfo.processInfo.environment)
  private let captureAccess: () -> Bool
  private let enumerateDisplays: () async throws -> [Display]
  private let notificationCenter: NotificationCenter
  private let workspaceNotificationCenter: NotificationCenter

  convenience init() {
    self.init(
      captureAccess: { CGPreflightScreenCaptureAccess() }, notificationCenter: .default,
      workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
      enumerateDisplays: { try await Self.watchedDisplays() })
  }

  /// Keep OS permission, notifications and display enumeration at the boundary for request-ordering tests.
  init(
    captureAccess: @escaping () -> Bool, notificationCenter: NotificationCenter,
    workspaceNotificationCenter: NotificationCenter, enumerateDisplays: @escaping () async throws -> [Display]
  ) {
    self.captureAccess = captureAccess
    self.enumerateDisplays = enumerateDisplays
    self.notificationCenter = notificationCenter
    self.workspaceNotificationCenter = workspaceNotificationCenter
  }

  func handle(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    guard !isShutdown, !Task.isCancelled else { return .init(status: "stopped") }
    guard request.version == 1 else {
      return .init(status: "unavailable", message: "Update Codevisor to use Screen Sharing.")
    }
    // Register before any suspension, including cleanup of an expired previous session.
    let attempt: UUID?
    if request.operation == .start || request.operation == .restart {
      let id = UUID()
      pendingStarts[id] = .init(request)
      attempt = id
    } else {
      attempt = nil
    }
    defer { if let attempt { pendingStarts.removeValue(forKey: attempt) } }
    installObservers()
    if lease.isExpired(now: ProcessInfo.processInfo.systemUptime), let current { await end(current) }
    guard !isShutdown else { return .init(status: "stopped") }
    if let attempt, Task.isCancelled || pendingStarts[attempt] == nil { return .init(status: "stopped") }
    switch request.operation {
    case .setScale:
      // A VNC desktop's operation (851-2339); a Mac's display scale isn't the viewer's to set.
      return .init(status: "unsupported", message: "This Mac's display scale can't be set remotely.")
    case .stop:
      stopGeneration += 1
      let owner = ScreenSharingHostLease.Owner(request)
      pendingStarts = pendingStarts.filter { $0.value != owner }
      if let current, current.owner == .init(request) { await end(current) }
      return .init(status: "stopped")
    case .heartbeat:
      guard let current, !current.stopping,
        lease.renew(.init(request), now: ProcessInfo.processInfo.systemUptime)
      else {
        if let lastEnd, lastEnd.owner == .init(request) { return .init(status: "failed", message: lastEnd.reason) }
        return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
      }
      let labels = current.metrics.snapshot().labels
      // A capture being restarted clears its error to "" (851-2375).
      if let error = [labels["captureError"], labels["encoderError"]].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
        await end(current)
        return .init(status: "failed", message: error)
      }
      return .init(status: current.state, message: current.notice)
    case .capabilities:
      guard captureAccess() else { return permissionRequired() }
      do {
        return .init(
          status: current == nil ? "available" : "busy", displays: try await enumerateDisplays().map(\.description),
          connectivity: try connectivity.make(viewerId: request.viewerId))
      } catch { return .init(status: "unavailable", message: error.localizedDescription) }
    case .start, .restart:
      var replacement: ScreenSharingHostLease.ReplacementPermit?
      if request.operation == .restart {
        // A fresh media peer avoids replaying old decoder, cursor or input
        // state. Renewal still requires the existing live host lease.
        guard let old = current, !old.stopping, old.owner == .init(request),
          old.display.id == request.displayId,
          let permit = lease.replacementPermit(
            old.owner, revision: stopGeneration, now: ProcessInfo.processInfo.systemUptime)
        else {
          return .init(
            status: "stopped", message: "The host ended this sharing session. Connect again to start a new one.")
        }
        replacement = permit
        await end(old)
        guard !isShutdown, permit.isValid(revision: stopGeneration, now: ProcessInfo.processInfo.systemUptime) else {
          return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
        }
      }
      guard current == nil else {
        return .init(status: "busy", message: "This Mac is already sharing with another viewer.")
      }
      guard captureAccess() else { return permissionRequired() }
      guard let offer = request.offer, offer.utf8.count <= 256 * 1024,
        offer.contains("a=fingerprint:sha-256 "), let displayId = request.displayId
      else {
        return .init(status: "failed", message: "Invalid Screen Sharing request.")
      }
      do {
        let available = try await enumerateDisplays()
        try Task.checkCancellation()
        guard !isShutdown, let attempt, pendingStarts[attempt] != nil else { return .init(status: "stopped") }
        if let replacement, !replacement.isValid(revision: stopGeneration, now: ProcessInfo.processInfo.systemUptime) {
          return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
        }
        // Display enumeration suspends; another request may reserve the host.
        guard current == nil else {
          return .init(status: "busy", message: "This Mac is already sharing with another viewer.")
        }
        guard let display = available.first(where: { $0.description.id == displayId }) else {
          return .init(status: "unavailable", message: "The selected display is no longer available.")
        }
        // Parsed once per process (failures cached too); an unknown value fails the request rather than selecting
        // the candidate, and both roles in this app process read the same answer.
        let profile = try ScreenSharingDiagnosticProfile.process()
        let session = try Session(
          request: request, display: display.description, displayID: display.id,
          connectivity: connectivity.make(viewerId: request.viewerId), profile: profile)
        guard lease.reserve(session.owner, now: ProcessInfo.processInfo.systemUptime) else {
          session.peer.close()
          return .init(status: "busy", message: "This Mac is already sharing with another viewer.")
        }
        current = session
        lastEnd = nil
        configure(session)
        do {
          try await session.peer.accept(.init(kind: "offer", sdp: offer))
          let answer = try await session.peer.makeDescription(offer: false)
          // Main 4:4:4 needs BGRA frames to keep chroma; the others take NV12 (851-2381).
          if let codec = ScreenSharingVideoCodec.negotiated(inDescription: answer.sdp) {
            session.capture.pixelFormat = codec.capturePixelFormat
            session.metrics.label("negotiatedCodec", codec.rawValue)
          }
          try Task.checkCancellation()
          guard current === session, !session.stopping else { throw CancellationError() }
          return .init(status: "connecting", answer: answer.sdp)
        } catch { await end(session); throw error }
      } catch { return .init(status: "failed", message: error.localizedDescription) }
    }
  }

  func shutdown() async {
    isShutdown = true
    pendingStarts.removeAll()
    stopGeneration += 1
    if let current { await end(current) }
    for observer in observers {
      notificationCenter.removeObserver(observer);
      workspaceNotificationCenter.removeObserver(observer)
    }
    observers = []
  }

  private func configure(_ session: Session) {
    session.qualityTask = Task { [weak self, weak session] in
      guard let initial = session?.configuration else { return }
      var base = initial
      var quality = ScreenSharingAdaptiveQuality(
        configuration: initial, fullQualityBitrate: ScreenSharingHostService.fullQualityBitrate,
        warmUp: ScreenSharingHostService.estimateWarmUp)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let session, !session.stopping else { return }
        // A new size (851-2376) is a new full-quality level to adapt from.
        if session.configuration != base {
          base = session.configuration
          quality = ScreenSharingAdaptiveQuality(
            configuration: base, fullQualityBitrate: ScreenSharingHostService.fullQualityBitrate,
            warmUp: ScreenSharingHostService.estimateWarmUp)
        }
        guard session.state == "viewing" else { continue }
        let statistics = await session.peer.statistics()
        guard !Task.isCancelled, !session.stopping else { return }
        guard session.state == "viewing" else { continue }
        let bandwidth = statistics.first { $0.key.hasSuffix(".availableOutgoingBitrate") }.flatMap { Double($0.value) }
        if let configuration = quality.update(availableBitrate: bandwidth, now: ProcessInfo.processInfo.systemUptime) {
          session.peer.updateVideoConfiguration(configuration)
          // Level-aware request: the override only at level 0, the video rate below it. Validation, the SCK call and
          // the label commit all happen inside the single capture path.
          do {
            try await session.capture.update(
              configuration: configuration,
              captureIntervalFPS: session.profile?.captureIntervalFPS(adaptiveLevel: quality.level))
          } catch {
            if !Task.isCancelled {
              session.metrics.label("captureError", "Unable to adjust capture quality.")
              self?.scheduleEnd(session)
            }
            return
          }
          session.metrics.label("adaptiveQualityLevel", String(quality.level))
        }
      }
    }
    let pasteboard = ScreenSharingPasteboard()
    let clipboard = ScreenSharingClipboardTransfer(
      send: { [weak session] in session?.peer.clipboardChannel.send($0) ?? false },
      canReceiveUnsolicited: { [weak session] in session?.state == "viewing" && session?.stopping == false },
      read: { try pasteboard.read() }, write: { try pasteboard.write($0) })
    session.clipboard = clipboard
    session.peer.clipboardChannel.onMessage = { [weak clipboard] in clipboard?.receive($0) }
    session.peer.clipboardChannel.onAvailabilityChanged = { [weak clipboard] available in
      if !available { clipboard?.cancel(reason: "The clipboard channel closed.") }
    }
    session.injector = ScreenSharingInputInjector(displayBounds: CGDisplayBounds(session.displayID))
    let control = ScreenSharingHostControl(
      availability: { [weak session] in
        guard let session, !session.stopping, session.state == "viewing" else {
          return "Wait for live video before requesting control."
        }
        guard session.injector?.isAvailable == true else { return "Native input is unavailable on this Mac." }
        guard AXIsProcessTrusted() else {
          return
            "Allow Codevisor in System Settings → Privacy & Security → Accessibility on the host Mac, then request control again."
        }
        return nil
      },
      inject: { [weak session] in
        session?.metrics.increment("controlInputEvents"); session?.injector?.post($0)
      }, send: { [weak session] in session?.peer.controlChannel.send($0) ?? false })
    session.control = control
    session.peer.controlChannel.onMessage = { [weak control] in control?.receive($0) }
    session.peer.controlChannel.onAvailabilityChanged = { [weak control] available in
      if !available { control?.revoke("The control channel closed.") }
    }
    control.onChanged = { [weak self] active in self?.indicator.setControlling(active) }
    configureCursor(session)
    configureAudio(session)
    configureDisplay(session)

    session.capture.onStopped = { [weak self, weak session] message in
      guard let self, let session else { return }
      self.captureStopped(session, message: message)
    }
    session.peer.onConnectionChanged = { [weak self, weak session] state in
      guard let self, let session, self.current === session, !session.stopping else { return }
      if state == "connected", session.captureTask == nil {
        session.captureTask = Task { [weak self, weak session] in
          guard let self, let session else { return }
          do {
            let baseline = ScreenSharingCaptureStallRecovery.activity(session.metrics.snapshot().counters)
            try await self.startWatchedCapture(session, reason: "viewer connected")
            guard self.current === session, !session.stopping else { try? await session.capture.stop(); return }
            session.state = "viewing"
            session.notice = nil
            session.displaySleepAssertion = ScreenSharingDisplaySleepAssertion(reason: "Codevisor Screen Sharing")
            self.indicator.show(display: session.display.name) { [weak self, weak session] in
              guard let self, let session else { return }
              self.scheduleEnd(session)
            }
            await self.recoverStalledCapture(session, baseline: baseline)
          } catch {
            await self.end(session, reason: (error as? ScreenSharingError)?.localizedDescription ?? Self.captureFailed)
          }
        }
      } else if ["disconnected", "failed", "closed"].contains(state) {
        session.state = "reconnecting"
        session.control?.revoke("The connection was interrupted.")
        session.clipboard?.cancel(reason: "The connection was interrupted.")
        let pending = session.captureTask
        pending?.cancel()
        session.captureTask = Task {
          await pending?.value
          try? await session.capture.stop()
        }
      }
    }
    session.watchdog = Task { [weak self, weak session] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self, let session, self.current === session else { return }
        session.control?.checkDeadline()
        session.clipboard?.tick()
        if self.lease.isExpired(now: ProcessInfo.processInfo.systemUptime) { await self.end(session); return }
      }
    }
  }

  private func scheduleEnd(_ session: Session) {
    guard current === session else { return }
    stopGeneration += 1
    session.state = "stopping"
    session.control?.revoke("Screen sharing ended.")
    session.clipboard?.cancel(reason: "Screen sharing ended.")
    Task { await end(session, reason: "Screen sharing was stopped on the host Mac.") }
  }

  static let captureFailed = "The host Mac couldn't start capturing its screen. Try again."

  private func end(_ session: Session, reason: String? = nil) async {
    guard current === session, !session.stopping else { return }
    if let reason { lastEnd = (session.owner, reason) }
    session.stopping = true
    session.control?.revoke("Screen sharing ended.")
    session.clipboard?.cancel(reason: "Screen sharing ended.")
    let metrics = session.metrics.snapshot()
    Self.logger.info(
      "Host ended: \(session.state, privacy: .public), \(String(describing: metrics.counters), privacy: .public), \(String(describing: metrics.labels), privacy: .public)"
    )
    session.watchdog?.cancel()
    session.qualityTask?.cancel()
    session.cursor?.stop()
    session.capture.audio.set(nil)
    session.pendingResize?.cancel()
    session.resizing?.cancel()
    session.peer.close()
    session.captureTask?.cancel()
    // Capture invalidates its generation; a late startup stops its own stream. A wedged replayd
    // can hold the stop; the session ends anyway (851-2385).
    if await !ScreenSharingCaptureStallRecovery.stop({ try await session.capture.stop() }) {
      Self.logger.error("Capture didn't stop within 3 s; ending the session anyway")
    }
    indicator.hide()
    session.virtualDisplay?.release()
    session.virtualDisplay = nil
    session.displaySleepAssertion = nil
    _ = lease.release(session.owner)
    if current === session { current = nil }
  }

  private func permissionRequired() -> ServerScreenSharingReply {
    .init(
      status: "permission-required",
      message:
        "Allow Codevisor in System Settings → Privacy & Security → Screen & System Audio Recording on the host Mac, then retry."
    )
  }

  /// Shared by the system notification adapter and deterministic request-ordering coverage.
  func systemStopped() {
    stopGeneration += 1
    pendingStarts.removeAll()
    if let current { scheduleEnd(current) }
  }

  private func installObservers() {
    guard observers.isEmpty else { return }
    let stop: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated {
        self?.systemStopped()
      }
    }
    for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      observers.append(
        workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main, using: stop))
    }
    observers.append(
      notificationCenter.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.screenParametersChanged() } })
  }

  /// A display change ends the session, unless the session made it itself (851-2376).
  func screenParametersChanged() {
    if let current, ProcessInfo.processInfo.systemUptime < current.ownDisplayChangeUntil { return }
    systemStopped()
  }
}

extension ScreenSharingHostService {
  /// ScreenCaptureKit stopped the stream with an error (851-2375): restart it on the same
  /// session, a bounded number of times, with the viewer told why the picture paused.
  private func captureStopped(_ session: Session, message: String) {
    guard current === session, !session.stopping else { return }
    guard session.captureRestarts.allowsRestart(now: ProcessInfo.processInfo.systemUptime) else {
      Self.logger.error("Capture stopped again (\(message, privacy: .public)); ending the session")
      scheduleEnd(session)
      return
    }
    Self.logger.notice("Capture stopped (\(message, privacy: .public)); restarting it")
    session.metrics.increment("captureRestarts")
    session.metrics.label("captureError", "")
    session.control?.revoke("The host's screen capture stopped.")
    session.state = "connecting"
    session.notice = "Capture stopped, restarting…"
    let pending = session.captureTask
    pending?.cancel()
    session.captureTask = Task { [weak self, weak session] in
      await pending?.value
      try? await Task.sleep(for: ScreenSharingCaptureRestartPolicy.delay)
      guard let self, let session, self.current === session, !session.stopping, !Task.isCancelled else { return }
      let baseline = ScreenSharingCaptureStallRecovery.activity(session.metrics.snapshot().counters)
      do {
        try? await session.capture.stop()
        try await self.startWatchedCapture(session, reason: "capture stopped")
      } catch {
        guard self.current === session, !session.stopping, !Task.isCancelled else { return }
        Self.logger.error("Capture restart failed: \(error.localizedDescription, privacy: .public)")
        session.metrics.label("captureError", "The host Mac's screen capture stopped and couldn't be restarted.")
        return
      }
      guard self.current === session, !session.stopping else { return }
      session.state = "viewing"
      session.notice = nil
      await self.recoverStalledCapture(session, baseline: baseline)
    }
  }

  func startCapture(_ session: Session) async throws {
    try await session.capture.start(
      displayID: session.captureDisplayID, configuration: session.configuration,
      sink: session.peer.frameSender, metrics: session.metrics)
  }

  func captureRecovery(_ session: Session) -> ScreenSharingCaptureStallRecovery {
    ScreenSharingCaptureStallRecovery.live(
      metrics: session.metrics,
      restartCapture: { [weak self, weak session] in
        guard let self, let session, self.current === session, !session.stopping else { throw CancellationError() }
        try await session.capture.stop()
        try await self.startCapture(session)
      },
      log: { Self.logger.notice("\($0, privacy: .public)") },
      onStalled: { [weak session] in
        guard let session, !session.stopping else { return }
        Self.logger.notice("Capture stalled (no frames, or a start that didn't return); recovering")
        session.metrics.increment("captureStalls")
        session.control?.revoke("The host's screen capture stalled.")
        session.state = "connecting"
        session.notice = "Capture stalled, restarting…"
      })
  }

  private func recoverStalledCapture(_ session: Session, baseline: Int) async {
    let recovery = captureRecovery(session)
    guard let outcome = try? await recovery.run(baseline: baseline), current === session, !session.stopping else {
      return
    }
    switch outcome {
    case .healthy: return
    case .recovered(let restartedDaemon):
      Self.logger.notice("Capture recovered\(restartedDaemon ? " after restarting replayd" : "", privacy: .public)")
      session.metrics.increment("captureStallRecoveries")
      session.state = "viewing"
      session.notice = nil
    case .failed:
      Self.logger.error("Capture stalled and did not recover")
      session.notice = nil
      session.metrics.label(
        "captureError", "The host Mac couldn't capture its screen. Restarting the host Mac fixes this if it persists.")
    }
  }
}
