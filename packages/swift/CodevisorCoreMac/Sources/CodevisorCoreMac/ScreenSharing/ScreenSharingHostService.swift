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
  private(set) var current: ScreenSharingHostSession? { didSet { hosting.isHosting = current != nil } }
  var lastEnd: (owner: ScreenSharingHostLease.Owner, ending: ScreenSharingHostEnding)?
  var displaced: (owner: ScreenSharingHostLease.Owner, by: ScreenSharingHostLease.Owner)?
  var takeovers: [UUID: ScreenSharingHostLease.Owner] = [:]
  var challenges = ScreenSharingHostChallenges()
  var endedSessions: [(token: String, owner: ScreenSharingHostLease.Owner)] = []
  var displayChoice = ScreenSharingHostDisplayChoice()
  var logicalDisplays: ScreenSharingHostLogicalDisplays
  var displaySwitchWait: Duration = .seconds(10)
  var captureRestartDelay = ScreenSharingCaptureRestartPolicy.delay
  var onlineDisplays: () -> [ScreenSharingDisplayIdentity.Online] = ScreenSharingDisplayIdentity.online
  var startsCapture: (ScreenSharingHostSession) async throws -> Void = ScreenSharingHostService.startCaptureStream
  var virtualDisplaysAvailable: () -> Bool = { ScreenSharingHostVirtualDisplay.isAvailable }
  var isMirrored: (CGDirectDisplayID) -> Bool = { CGDisplayIsInMirrorSet($0) != 0 }
  private(set) var pendingStarts: [UUID: ScreenSharingHostLease.Owner] = [:]
  private(set) var isShutdown = false
  private var stopGeneration = 0
  private var lease = ScreenSharingHostLease()
  let indicator = ScreenSharingHostIndicator()
  private var observers: [NSObjectProtocol] = []
  let captureAccess: () -> Bool
  let enumerateDisplays: () async throws -> [Display]
  private let notificationCenter: NotificationCenter
  private let workspaceNotificationCenter: NotificationCenter
  let mediaEndpoint: ScreenSharingMediaEndpoint
  private let hosting: ScreenSharingHostActivity.Claim

  convenience init() {
    self.init(
      captureAccess: { CGPreflightScreenCaptureAccess() }, notificationCenter: .default,
      workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
      enumerateDisplays: { try await Self.watchedDisplays() })
  }

  init(
    captureAccess: @escaping () -> Bool, notificationCenter: NotificationCenter,
    workspaceNotificationCenter: NotificationCenter, enumerateDisplays: @escaping () async throws -> [Display],
    mediaEndpoint: ScreenSharingMediaEndpoint = .shared, logicalDisplays: ScreenSharingHostLogicalDisplays = .init(),
    activity: ScreenSharingHostActivity = .shared
  ) {
    self.mediaEndpoint = mediaEndpoint
    hosting = activity.claim()
    self.logicalDisplays = logicalDisplays
    self.captureAccess = captureAccess
    self.enumerateDisplays = enumerateDisplays
    self.notificationCenter = notificationCenter
    self.workspaceNotificationCenter = workspaceNotificationCenter
  }

  func handle(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    describingSession(await respond(to: request), for: request)
  }

  private func respond(to request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    guard !isShutdown, !Task.isCancelled else { return .init(status: "stopped") }
    guard request.version == 1 else { return ScreenSharingHostRefusal.updateNeeded.reply }
    guard Self.isIdentified(request) else {
      return ScreenSharingHostRefusal.viewerUpdateNeeded(machine: Self.machineName()).reply
    }
    if let refusal = await refusalBeforeRegistering(request) { return refusal }
    let attempt = request.operation == .start ? registerStart(request) : nil
    defer { if let attempt { forget(attempt) } }
    installObservers()
    if lease.isExpired(now: ProcessInfo.processInfo.systemUptime), let current {
      Self.logger.notice(
        "Lease expired: no heartbeat or media connection from the viewer for \(Int(ScreenSharingHostLease.lifetime)) s")
      await end(current)
    }
    guard !isShutdown else { return .init(status: "stopped") }
    if let attempt, Task.isCancelled || pendingStarts[attempt] == nil { return .init(status: "stopped") }
    switch request.operation {
    case .setScale:
      return .init(status: "unsupported", message: "This Mac's display scale can't be set remotely.")
    case .stop:
      stopGeneration += 1
      pendingStarts = pendingStarts.filter { !stops(request, pending: $0.value) }
      if let current, stops(request, current) { await end(current) }
      return .init(status: "stopped")
    case .heartbeat:
      guard let current, !current.stopping, renewsLease(of: current, for: request) else {
        return sessionlessReply(to: request)
      }
      let change = await sharing(request, in: current)
      guard self.current === current, !current.stopping else { return sessionlessReply(to: request) }
      if let failure = current.failure {
        await end(current)
        return .init(status: "failed", message: failure)
      }
      return heartbeatReply(from: current, after: change)
    case .capabilities:
      return await capabilities()
    case .start:
      guard let attempt else { return .init(status: "stopped") }
      return await start(request, attempt: attempt)
    case .restart:
      return ScreenSharingHostRefusal.viewerUpdateNeeded(machine: Self.machineName()).reply
    }
  }

  private func capabilities() async -> ServerScreenSharingReply {
    guard captureAccess() else { return ScreenSharingHostRefusal.permissionMissing.reply }
    do {
      var reply = ServerScreenSharingReply(
        status: current == nil ? "available" : "busy",
        displays: listed(try await enumerateDisplays()).map(\.description))
      if mediaEndpoint.isAvailable { reply.engines = [ScreenSharingEngine.v2.rawValue] }
      reply.challenge = await challenge()
      return reply
    } catch { return failed("Display listing", error, status: "unavailable") }
  }

  private func renewsLease(
    of session: ScreenSharingHostSession, for request: ServerScreenSharingRequest
  ) -> Bool {
    guard let token = request.session else { return false }

    return session.hasToken(token) && lease.renew(session.owner, now: ProcessInfo.processInfo.systemUptime)
  }

  private func forget(_ attempt: UUID) {
    pendingStarts.removeValue(forKey: attempt)
    takeovers.removeValue(forKey: attempt)
  }

  private func registerStart(_ request: ServerScreenSharingRequest) -> UUID? {
    guard let owner = Owner(request) else { return nil }

    pendingStarts = pendingStarts.filter { $0.value != owner }
    let attempt = UUID()
    pendingStarts[attempt] = owner
    return attempt
  }

  private func start(_ request: ServerScreenSharingRequest, attempt: UUID) async -> ServerScreenSharingReply {
    guard let owner = Owner(request) else { return .init(status: "stopped") }

    if let old = current {
      if let refusal = await displace(old, by: owner, for: request, attempt: attempt) { return refusal }
      guard !isShutdown, pendingStarts[attempt] != nil else { return .init(status: "stopped") }
    }
    guard current == nil else { return inUse }
    guard captureAccess() else { return ScreenSharingHostRefusal.permissionMissing.reply }
    guard mediaEndpoint.isAvailable else { return .init(status: "failed", message: Self.endpointUnavailable) }
    guard let (displayId, viewerMedia) = startMedia(request) else {
      return .init(status: "failed", message: "Invalid Screen Sharing request.")
    }
    do {
      return try await startSession(
        request, by: owner, attempt: attempt, displayId: displayId, viewerMedia: viewerMedia)
    } catch { return failed("Start", error, status: "failed") }
  }

  private func startSession(
    _ request: ServerScreenSharingRequest, by owner: Owner, attempt: UUID, displayId: String?,
    viewerMedia: ServerScreenSharingMediaAddress
  ) async throws -> ServerScreenSharingReply {
    let available = try await displaysToShare()
    try Task.checkCancellation()
    guard !isShutdown, pendingStarts[attempt] != nil else { return .init(status: "stopped") }
    guard current == nil else { return inUse }
    let candidates = listed(available)
    guard let display = displayChoice.display(for: owner, asking: displayId, among: candidates) else {
      return ScreenSharingHostRefusal.noDisplay.reply
    }
    let session = try ScreenSharingHostSession(
      owner: owner, request: request, display: display.description, displayID: display.id,
      viewerEndpointId: viewerMedia.endpointId, encoder: .forViewer(chroma: request.chroma))
    if Task.isCancelled {
      session.peer.close()
      throw CancellationError()
    }
    guard !isShutdown, pendingStarts[attempt] != nil else {
      session.peer.close()
      return .init(status: "stopped")
    }
    guard current == nil, lease.reserve(session.owner, now: ProcessInfo.processInfo.systemUptime) else {
      session.peer.close()
      return inUse
    }
    current = session
    lastEnd = nil
    if displaced?.owner == session.owner { displaced = nil }
    if let taken = takeovers[attempt] { displaced = (taken, session.owner) }
    describe(session, among: available)
    configureChannels(session)
    return await startV2(session)
  }

  func startMedia(
    _ request: ServerScreenSharingRequest
  ) -> (displayId: String?, viewerMedia: ServerScreenSharingMediaAddress)? {
    guard request.engine == ScreenSharingEngine.v2.rawValue, let viewerMedia = request.media else { return nil }

    guard let app = request.app, app.key.lowercased() == viewerMedia.endpointId.lowercased() else { return nil }

    return (request.displayId, viewerMedia)
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
    let control = Self.control(for: session)
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
        do { try await Task.sleep(for: .seconds(Self.watchInterval)) } catch { return }
        guard let self, let session, self.current === session else { return }
        guard await self.watch(session) else { return }
      }
    }
  }

  private static func control(for session: ScreenSharingHostSession) -> ScreenSharingHostControl {
    ScreenSharingHostControl(
      looksEvery: watchInterval,
      availability: { [weak session] in
        guard let session, !session.awaitsLiveVideo else {
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
  }

  func renewLease(for session: ScreenSharingHostSession) {
    guard current === session else { return }
    _ = lease.renew(session.owner, now: ProcessInfo.processInfo.systemUptime)
  }

  private func watch(_ session: ScreenSharingHostSession) async -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    session.control?.checkDeadline()
    session.clipboard?.tick()
    if session.state == "viewing", session.control?.lease != nil { session.clipboard?.poll() }
    guard lease.isExpired(now: now) else { return true }
    Self.logger.notice(
      "Lease expired: no heartbeat or media connection from the viewer for \(Int(ScreenSharingHostLease.lifetime)) s")
    await end(session)
    return false
  }

  private func startViewing(_ session: ScreenSharingHostSession) async {
    do {
      let baseline = ScreenSharingCaptureStallRecovery.activity(session.metrics.counters())
      await updateDisplay(session)
      guard current === session, !session.stopping, !Task.isCancelled else { return }
      try await startWatchedCapture(session, reason: "viewer connected")
      guard current === session, !session.stopping else { try? await session.capture.stop(); return }
      try await reconcileCapture(session)
      session.state = "viewing"
      session.notice = nil
      session.displaySleepAssertion = ScreenSharingDisplaySleepAssertion(reason: "Codevisor Screen Sharing")
      indicator.show(display: session.display.name, viewer: session.owner.name) { [weak self, weak session] in
        guard let self, let session else { return }
        self.scheduleEnd(session, as: .stoppedOnHost)
      }
      await recoverStalledCapture(session, baseline: baseline)
    } catch {
      await end(session, as: .captureFailed(ScreenSharingHostFailure(error)))
    }
  }

  private func scheduleEnd(_ session: ScreenSharingHostSession, as ending: ScreenSharingHostEnding) {
    guard current === session else { return }
    stopGeneration += 1
    session.state = "stopping"
    session.control?.revoke("Screen sharing ended.")
    session.clipboard?.cancel(reason: "Screen sharing ended.")
    lastEnd = (session.owner, ending)
    Task { await end(session, as: ending) }
  }

  static let watchInterval: TimeInterval = 0.25

  nonisolated static let captureFailed = "The host Mac couldn't start capturing its screen. Try again."

  func end(_ session: ScreenSharingHostSession, as cause: ScreenSharingHostEnding? = nil) async {
    guard current === session else { return }
    if let ending = session.ending { return await ending.value }
    if let cause { lastEnd = (session.owner, cause) }
    forgetDisplacement(endedBy: session)
    rememberEnded(session)
    session.stopping = true
    session.control?.revoke("Screen sharing ended.")
    session.clipboard?.cancel(reason: "Screen sharing ended.")
    let metrics = session.metrics.snapshot()
    Self.logger.notice(
      "Host ended (\(cause?.reason?.rawValue ?? cause?.message ?? "stopped", privacy: .public)): \(session.state, privacy: .public), \(String(describing: metrics.counters), privacy: .public), \(String(describing: metrics.labels), privacy: .public)"
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

  func systemStopped(_ ending: ScreenSharingHostEnding) {
    stopGeneration += 1
    pendingStarts.removeAll()
    if let current { scheduleEnd(current, as: ending) }
  }

  private func installObservers() {
    guard observers.isEmpty else { return }
    let endings: [(Notification.Name, ScreenSharingHostEnding)] = [
      (NSWorkspace.screensDidSleepNotification, .displayAsleep),
      (NSWorkspace.sessionDidResignActiveNotification, .sessionSwitched),
    ]
    for (name, ending) in endings {
      observers.append(
        workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.systemStopped(ending) }
        })
    }
    observers.append(
      workspaceNotificationCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.displayWoke() } })
    observers.append(
      notificationCenter.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.screenParametersChanged() } })
  }

}

extension ScreenSharingHostService {
  private func captureStopped(_ session: ScreenSharingHostSession, message: String) {
    guard current === session, !session.stopping else { return }
    if session.state == "viewing", followsToAnotherDisplay(session) {
      Self.logger.notice("Capture stopped (\(message, privacy: .public)); its display went away")
      return
    }
    guard session.captureRestarts.allowsRestart(now: ProcessInfo.processInfo.systemUptime) else {
      Self.logger.error("Capture stopped again (\(message, privacy: .public)); ending the session")
      scheduleEnd(session, as: .captureLost)
      return
    }
    Self.logger.notice("Capture stopped (\(message, privacy: .public)); restarting it")
    session.metrics.increment("captureRestarts")
    session.captureFailure = nil
    session.control?.revoke("The host's screen capture stopped.")
    session.state = "connecting"
    session.notice = "Capture stopped, restarting…"
    let pending = session.captureTask
    pending?.cancel()
    session.captureTask = Task { [weak self, weak session] in
      await pending?.value
      try? await Task.sleep(for: self?.captureRestartDelay ?? .zero)
      guard let self, let session, self.current === session, !session.stopping, !Task.isCancelled else { return }
      let baseline = ScreenSharingCaptureStallRecovery.activity(session.metrics.counters())
      do {
        try? await session.capture.stop()
        try await self.restartOnSettledDisplay(session)
        try await self.reconcileCapture(session)
      } catch {
        guard self.current === session, !session.stopping, !Task.isCancelled else { return }
        return await self.restartFailed(session, error)
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
      session.captureFailure =
        "The host Mac couldn't capture its screen. Restarting the host Mac fixes this if it persists."
    }
  }
}
