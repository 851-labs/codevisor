import AppKit
import CodevisorNet
import CodevisorCore
import ScreenSharing
import ScreenSharingV2
import Foundation
import OSLog

@MainActor
final class ScreenSharingHostService {
  typealias Display = (id: UInt32, description: ServerScreenSharingDisplay)
  static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  private(set) var current: ScreenSharingHostSession?
  private var lastEnd: (owner: ScreenSharingHostLease.Owner, reason: String)?
  private var pendingStarts: [UUID: ScreenSharingHostLease.Owner] = [:]
  private var isShutdown = false
  private var stopGeneration = 0
  private var lease = ScreenSharingHostLease()
  private let indicator = ScreenSharingHostIndicator()
  private var observers: [NSObjectProtocol] = []
  private let captureAccess: () -> Bool
  private let enumerateDisplays: () async throws -> [Display]
  private let notificationCenter: NotificationCenter
  private let workspaceNotificationCenter: NotificationCenter
  private let mediaEndpoint: ScreenSharingMediaEndpoint

  convenience init() {
    self.init(
      captureAccess: { CGPreflightScreenCaptureAccess() }, notificationCenter: .default,
      workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
      enumerateDisplays: { try await Self.watchedDisplays() })
  }

  init(
    captureAccess: @escaping () -> Bool, notificationCenter: NotificationCenter,
    workspaceNotificationCenter: NotificationCenter, enumerateDisplays: @escaping () async throws -> [Display],
    mediaEndpoint: ScreenSharingMediaEndpoint = .shared
  ) {
    self.mediaEndpoint = mediaEndpoint
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
    let attempt = [.start, .restart].contains(request.operation) ? registerStart(request) : nil
    defer { if let attempt { pendingStarts.removeValue(forKey: attempt) } }
    installObservers()
    if lease.isExpired(now: ProcessInfo.processInfo.systemUptime), let current { await end(current) }
    guard !isShutdown else { return .init(status: "stopped") }
    if let attempt, Task.isCancelled || pendingStarts[attempt] == nil { return .init(status: "stopped") }
    switch request.operation {
    case .setScale:
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
      if let error = ["captureError", "encoderError"].compactMap(current.metrics.label).first(where: { !$0.isEmpty }) {
        await end(current)
        return .init(status: "failed", message: error)
      }
      return .init(status: current.state, message: current.notice)
    case .capabilities:
      guard captureAccess() else { return permissionRequired() }
      do {
        var reply = ServerScreenSharingReply(
          status: current == nil ? "available" : "busy", displays: try await enumerateDisplays().map(\.description))
        if mediaEndpoint.isAvailable { reply.engines = [ScreenSharingEngine.v2.rawValue] }
        return reply
      } catch { return .init(status: "unavailable", message: error.localizedDescription) }
    case .start, .restart:
      guard let attempt else { return .init(status: "stopped") }
      return await start(request, attempt: attempt)
    }
  }

  private func registerStart(_ request: ServerScreenSharingRequest) -> UUID {
    let owner = ScreenSharingHostLease.Owner(request)
    pendingStarts = pendingStarts.filter { !$0.value.isSamePane(as: owner) }
    let attempt = UUID()
    pendingStarts[attempt] = owner
    return attempt
  }

  private func start(_ request: ServerScreenSharingRequest, attempt: UUID) async -> ServerScreenSharingReply {
    var replacement: ScreenSharingHostLease.ReplacementPermit?
    if request.operation == .restart {
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
    if request.operation == .start, let old = current, old.owner.isSamePane(as: .init(request)) {
      await end(old)
      guard !isShutdown, pendingStarts[attempt] != nil else { return .init(status: "stopped") }
    }
    guard current == nil else {
      return .init(status: "busy", message: "This Mac is already sharing with another viewer.")
    }
    guard captureAccess() else { return permissionRequired() }
    guard mediaEndpoint.isAvailable else {
      return .init(status: "failed", message: "This Mac's screen-sharing endpoint isn't available.")
    }
    guard let (displayId, viewerMedia) = startMedia(request) else {
      return .init(status: "failed", message: "Invalid Screen Sharing request.")
    }
    do {
      return try await startSession(
        request, attempt: attempt, replacement: replacement, displayId: displayId, viewerMedia: viewerMedia)
    } catch { return .init(status: "failed", message: error.localizedDescription) }
  }

  private func startSession(
    _ request: ServerScreenSharingRequest, attempt: UUID, replacement: ScreenSharingHostLease.ReplacementPermit?,
    displayId: String, viewerMedia: ServerScreenSharingMediaAddress
  ) async throws -> ServerScreenSharingReply {
    let available = try await enumerateDisplays()
    try Task.checkCancellation()
    guard !isShutdown, pendingStarts[attempt] != nil else { return .init(status: "stopped") }
    if let replacement, !replacement.isValid(revision: stopGeneration, now: ProcessInfo.processInfo.systemUptime) {
      return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
    }
    guard current == nil else {
      return .init(status: "busy", message: "This Mac is already sharing with another viewer.")
    }
    guard let display = available.first(where: { $0.description.id == displayId }) else {
      return .init(status: "unavailable", message: "The selected display is no longer available.")
    }
    let session = try ScreenSharingHostSession(
      request: request, display: display.description, displayID: display.id,
      viewerEndpointId: viewerMedia.endpointId, encoder: .forViewer(chroma: request.chroma))
    if Task.isCancelled {
      session.peer.close()
      throw CancellationError()
    }
    guard !isShutdown, pendingStarts[attempt] != nil else {
      session.peer.close()
      return .init(status: "stopped")
    }
    if let replacement, !replacement.isValid(revision: stopGeneration, now: ProcessInfo.processInfo.systemUptime) {
      session.peer.close()
      return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
    }
    guard current == nil, lease.reserve(session.owner, now: ProcessInfo.processInfo.systemUptime) else {
      session.peer.close()
      return .init(status: "busy", message: "This Mac is already sharing with another viewer.")
    }
    current = session
    lastEnd = nil
    configureChannels(session)
    return await startV2(session)
  }

  private func startMedia(
    _ request: ServerScreenSharingRequest
  ) -> (displayId: String, viewerMedia: ServerScreenSharingMediaAddress)? {
    guard request.engine == ScreenSharingEngine.v2.rawValue, let viewerMedia = request.media,
      let displayId = request.displayId
    else { return nil }

    return (displayId, viewerMedia)
  }

  func mediaEndpointHandle() async -> NetEndpointHandle? {
    await mediaEndpoint.ready()
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

  private func configureChannels(_ session: ScreenSharingHostSession) {
    let clipboard = ScreenSharingHostClipboard(
      channel: session.peer.channels.clipboard,
      canReceiveUnsolicited: { [weak session] in session?.state == "viewing" && session?.stopping == false })
    session.clipboard = clipboard
    session.peer.channels.clipboardSharing.onMessage = { [weak clipboard, weak session] message in
      guard let reply = clipboard?.receive(message) else { return }
      session?.peer.channels.clipboardSharing.send(reply)
    }
    let control = ScreenSharingHostControl(
      availability: { [weak session] in
        guard let session, !session.stopping, session.state == "viewing" || session.hasSentVideo else {
          return "Wait for live video before requesting control."
        }
        guard session.injector.isAvailable else { return "Native input is unavailable on this Mac." }
        guard AXIsProcessTrusted() else {
          return
            "Allow Codevisor in System Settings → Privacy & Security → Accessibility on the host Mac, then request control again."
        }
        return nil
      },
      inject: { [weak session] in
        session?.metrics.increment("controlInputEvents"); session?.injector.post($0)
      }, send: { [weak session] in session?.peer.channels.control.send($0) ?? false })
    session.control = control
    session.peer.channels.control.onMessage = { [weak control] in control?.receive($0) }
    session.peer.channels.control.onAvailabilityChanged = { [weak control] available in
      if !available { control?.revoke("The control channel closed.") }
    }
    control.onChanged = { [weak self] active in self?.indicator.setControlling(active) }
    session.configureMediaSubscriptions()
    configureDisplay(session)
    configureVideoFormat(session)

    session.capture.onStopped = { [weak self, weak session] message in
      guard let self, let session else { return }
      self.captureStopped(session, message: message)
    }
    session.peer.onConnectionChanged = { [weak self, weak session] state in
      guard let self, let session, self.current === session, !session.stopping else { return }
      if state == "connected", session.captureTask == nil {
        session.captureTask = Task { [weak self, weak session] in
          guard let self, let session else { return }
          await self.startViewing(session)
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
        if session.state == "viewing", session.control?.lease != nil { session.clipboard?.poll() }
        if self.lease.isExpired(now: ProcessInfo.processInfo.systemUptime) { await self.end(session); return }
      }
    }
  }

  private func startViewing(_ session: ScreenSharingHostSession) async {
    do {
      let baseline = ScreenSharingCaptureStallRecovery.activity(session.metrics.counters())
      await updateDisplay(session)
      guard current === session, !session.stopping else { return }
      try await startWatchedCapture(session, reason: "viewer connected")
      guard current === session, !session.stopping else { try? await session.capture.stop(); return }
      try await reconcileCapture(session)
      session.state = "viewing"
      session.notice = nil
      session.displaySleepAssertion = ScreenSharingDisplaySleepAssertion(reason: "Codevisor Screen Sharing")
      indicator.show(display: session.display.name) { [weak self, weak session] in
        guard let self, let session else { return }
        self.scheduleEnd(session)
      }
      await recoverStalledCapture(session, baseline: baseline)
    } catch {
      await end(session, reason: (error as? ScreenSharingError)?.localizedDescription ?? Self.captureFailed)
    }
  }

  private func scheduleEnd(_ session: ScreenSharingHostSession) {
    guard current === session else { return }
    stopGeneration += 1
    session.state = "stopping"
    session.control?.revoke("Screen sharing ended.")
    session.clipboard?.cancel(reason: "Screen sharing ended.")
    Task { await end(session, reason: "Screen sharing was stopped on the host Mac.") }
  }

  static let captureFailed = "The host Mac couldn't start capturing its screen. Try again."

  func end(_ session: ScreenSharingHostSession, reason: String? = nil) async {
    guard current === session else { return }
    if let ending = session.ending { return await ending.value }
    if let reason { lastEnd = (session.owner, reason) }
    session.stopping = true
    session.control?.revoke("Screen sharing ended.")
    session.clipboard?.cancel(reason: "Screen sharing ended.")
    let metrics = session.metrics.snapshot()
    Self.logger.info(
      "Host ended: \(session.state, privacy: .public), \(String(describing: metrics.counters), privacy: .public), \(String(describing: metrics.labels), privacy: .public)"
    )
    session.watchdog?.cancel()
    session.mediaAccept?.cancel()
    session.stopMediaPublishing()
    session.pendingResize?.cancel()
    session.resizing?.cancel()
    session.peer.close()
    session.captureTask?.cancel()
    let ending = Task { [self] in
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
    session.ending = ending
    await ending.value
  }

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

}

extension ScreenSharingHostService {
  private func permissionRequired() -> ServerScreenSharingReply {
    .init(
      status: "permission-required",
      message:
        "Allow Codevisor in System Settings → Privacy & Security → Screen & System Audio Recording on the host Mac, then retry."
    )
  }

  private func captureStopped(_ session: ScreenSharingHostSession, message: String) {
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
      let baseline = ScreenSharingCaptureStallRecovery.activity(session.metrics.counters())
      do {
        try? await session.capture.stop()
        try await self.restartOnSettledDisplay(session)
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

  func captureRecovery(_ session: ScreenSharingHostSession) -> ScreenSharingCaptureStallRecovery {
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

  private func recoverStalledCapture(_ session: ScreenSharingHostSession, baseline: Int) async {
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
