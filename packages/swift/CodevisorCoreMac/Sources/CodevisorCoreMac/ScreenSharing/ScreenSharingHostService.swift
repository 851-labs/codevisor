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
  typealias Display = (id: UInt32, description: ServerScreenSharingDisplay)
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  @MainActor private final class Session {
    let owner: ScreenSharingHostLease.Owner
    let peer: ScreenSharingSender
    let capture: ScreenSharingCapture
    /// The explicit experimental profile in force for this process, or nil when it is OFF (the default).
    let profile: ScreenSharingDiagnosticProfile?
    let metrics: ScreenSharingMetrics
    let display: ServerScreenSharingDisplay
    let displayID: UInt32
    let configuration: ScreenSharingVideoConfiguration
    var state = "connecting"
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
        height: max(64, Int(Double(display.height) * scale) / 2 * 2))
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
      workspaceNotificationCenter: NSWorkspace.shared.notificationCenter, enumerateDisplays: Self.displays)
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
        return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
      }
      let labels = current.metrics.snapshot().labels
      if let error = labels["captureError"] ?? labels["encoderError"] {
        await end(current)
        return .init(status: "failed", message: error)
      }
      return .init(status: current.state)
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
        configure(session)
        do {
          try await session.peer.accept(.init(kind: "offer", sdp: offer))
          let answer = try await session.peer.makeDescription(offer: false)
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
      var quality = ScreenSharingAdaptiveQuality(configuration: initial)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let session, !session.stopping else { return }
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
    let injector = ScreenSharingInputInjector(displayBounds: CGDisplayBounds(session.displayID))
    let control = ScreenSharingHostControl(
      availability: { [weak session] in
        guard let session, !session.stopping, session.state == "viewing" else {
          return "Wait for live video before requesting control."
        }
        guard injector.isAvailable else { return "Native input is unavailable on this Mac." }
        guard AXIsProcessTrusted() else {
          return
            "Allow Codevisor in System Settings → Privacy & Security → Accessibility on the host Mac, then request control again."
        }
        return nil
      },
      inject: { [weak session] in
        session?.metrics.increment("controlInputEvents"); injector.post($0)
      }, send: { [weak session] in session?.peer.controlChannel.send($0) ?? false })
    session.control = control
    session.peer.controlChannel.onMessage = { [weak control] in control?.receive($0) }
    session.peer.controlChannel.onAvailabilityChanged = { [weak control] available in
      if !available { control?.revoke("The control channel closed.") }
    }
    control.onChanged = { [weak self] active in self?.indicator.setControlling(active) }

    session.capture.onStopped = { [weak self, weak session] _ in
      guard let self, let session else { return }
      self.scheduleEnd(session)
    }
    session.peer.onConnectionChanged = { [weak self, weak session] state in
      guard let self, let session, self.current === session, !session.stopping else { return }
      if state == "connected", session.captureTask == nil {
        session.captureTask = Task { [weak self, weak session] in
          guard let self, let session else { return }
          do {
            try await session.capture.start(
              displayID: session.displayID, configuration: session.configuration,
              sink: session.peer.frameSender, metrics: session.metrics)
            guard self.current === session, !session.stopping else { try? await session.capture.stop(); return }
            session.state = "viewing"
            self.indicator.show(display: session.display.name) { [weak self, weak session] in
              guard let self, let session else { return }
              self.scheduleEnd(session)
            }
          } catch { await self.end(session) }
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
    Task { await end(session) }
  }

  private func end(_ session: Session) async {
    guard current === session, !session.stopping else { return }
    session.stopping = true
    session.control?.revoke("Screen sharing ended.")
    session.clipboard?.cancel(reason: "Screen sharing ended.")
    let metrics = session.metrics.snapshot()
    Self.logger.info(
      "Host ended: \(session.state, privacy: .public), \(String(describing: metrics.counters), privacy: .public), \(String(describing: metrics.labels), privacy: .public)"
    )
    session.watchdog?.cancel()
    session.qualityTask?.cancel()
    session.peer.close()
    session.captureTask?.cancel()
    // Capture invalidates its generation; a late startup stops its own stream.
    try? await session.capture.stop()
    indicator.hide()
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

  private static func displays() async throws -> [Display] {
    try await ScreenSharingCapture.displays().compactMap { display in
      guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue() else { return nil }
      let identity = CFUUIDCreateString(nil, uuid) as String
      let mode = CGDisplayCopyDisplayMode(display.id)
      let pixelScale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1
      let name =
        NSScreen.screens.first {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }?.localizedName ?? "Display"
      return (
        display.id,
        ServerScreenSharingDisplay(
          id: identity, name: name,
          width: Int(Double(display.width) * pixelScale), height: Int(Double(display.height) * pixelScale))
      )
    }
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
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: .main, using: stop))
  }
}
