import CodevisorCore
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import ScreenSharing

struct ComputerUseShareKey: Hashable, Sendable {
  let sessionID: String
  let pid: pid_t
}

/// ScreenCaptureKit delivers picker observer callbacks on an internal queue,
/// while `SCStream` and `SCContentFilter` have not adopted `Sendable`. Keep the
/// unchecked crossing tightly scoped to the hop into this type's main-actor
/// state rather than asserting that the callbacks themselves run on main.
private struct ComputerUseUncheckedSendable<Value>: @unchecked Sendable {
  let value: Value
}

/// Maintains one native ScreenCaptureKit stream per controlled window. Session
/// permissions reference that shared stream, while model screenshots remain
/// on-demand through SCScreenshotManager.
@MainActor
final class ComputerUseNativeSharing: NSObject,
  SCStreamDelegate,
  SCContentSharingPickerObserver
{
  static let shared = ComputerUseNativeSharing()

  private struct Entry {
    let windowID: CGWindowID
    let stream: SCStream
    let publisher: ComputerUseFramePublisher
    var keys: Set<ComputerUseShareKey>
    var pointPixelScale: CGFloat
    var settings: ComputerUseNativePreviewSettings
    /// The window's last known frame, so a viewer's size request can resize
    /// the stream without waiting for a tool call.
    var windowFrame: CGRect
  }

  private var entriesByWindowID: [CGWindowID: Entry] = [:]
  private var windowIDByKey: [ComputerUseShareKey: CGWindowID] = [:]
  private var pendingKeysByWindowID: [CGWindowID: Set<ComputerUseShareKey>] = [:]
  private var pendingWindowIDByKey: [ComputerUseShareKey: CGWindowID] = [:]
  private var windowIDByStream: [ObjectIdentifier: CGWindowID] = [:]
  private var intentionallyStopping: Set<ObjectIdentifier> = []
  /// Live preview consumers per session. They outlive any one stream: a
  /// session that moves to another window keeps its viewers.
  private var sinksBySession: [String: [UUID: any ComputerUseFrameSink]] = [:]
  private let outputQueue = DispatchQueue(
    label: "com.codevisor.computer-use.screen-share",
    qos: .utility
  )

  private override init() {
    super.init()
    let picker = SCContentSharingPicker.shared
    picker.add(self)
    // Streams only ever originate from an active Computer Use session:
    // the picker is never presented, so nothing can create an unowned
    // one. A cap of 0 used to enforce that, but the system counts our own
    // per-window streams against it and stops them as if the user had —
    // which permanently revoked healthy sessions. Allow enough headroom
    // for one stream per controlled window.
    picker.maximumStreamCount = 32
  }

  deinit {
    SCContentSharingPicker.shared.remove(self)
  }

  func activate(
    sessionID: String,
    pid: pid_t,
    windowID: CGWindowID?,
    windowFrame: CGRect
  ) {
    guard let windowID, !sessionID.isEmpty else { return }
    let key = ComputerUseShareKey(sessionID: sessionID, pid: pid)
    guard !ComputerUseRevocations.shared.contains(key) else { return }

    if windowIDByKey[key] == windowID {
      refreshPreviewConfiguration(windowID: windowID, windowFrame: windowFrame)
      return
    }
    if pendingWindowIDByKey[key] == windowID { return }

    detach(key: key, intentional: true)

    if var entry = entriesByWindowID[windowID] {
      entry.keys.insert(key)
      entriesByWindowID[windowID] = entry
      windowIDByKey[key] = windowID
      refreshPreviewConfiguration(windowID: windowID, windowFrame: windowFrame)
      resubscribe(windowID: windowID)
      return
    }

    let beginsStart = pendingKeysByWindowID[windowID] == nil
    pendingKeysByWindowID[windowID, default: []].insert(key)
    pendingWindowIDByKey[key] = windowID
    guard beginsStart else { return }

    Task { @MainActor [weak self] in
      await self?.start(windowID: windowID)
    }
  }

  func end(sessionID: String) {
    let keys = Set(windowIDByKey.keys.filter { $0.sessionID == sessionID })
      .union(pendingWindowIDByKey.keys.filter { $0.sessionID == sessionID })
    keys.forEach { detach(key: $0, intentional: true) }
    ComputerUseRevocations.shared.clear(sessionID: sessionID)
    deactivatePickerIfIdle()
  }

  /// Detaches one session/app pairing without touching revocations; the
  /// caller decides whether the stop was a user decision worth revoking.
  func retire(key: ComputerUseShareKey) {
    detach(key: key, intentional: true)
    deactivatePickerIfIdle()
  }

  /// Stops sharing for a session that has gone idle. Unlike `end`, the
  /// session is not over — revocations stand, and the next tool call
  /// re-attaches — so this must not clear them.
  func release(sessionID: String) {
    let keys = Set(windowIDByKey.keys.filter { $0.sessionID == sessionID })
      .union(pendingWindowIDByKey.keys.filter { $0.sessionID == sessionID })
    keys.forEach { detach(key: $0, intentional: true) }
    deactivatePickerIfIdle()
  }

  /// The controlled app exited. Non-revoking: the same session may control
  /// a relaunched instance under a new pid.
  func targetTerminated(pid: pid_t) {
    let keys = Set(windowIDByKey.keys.filter { $0.pid == pid })
      .union(pendingWindowIDByKey.keys.filter { $0.pid == pid })
    keys.forEach { detach(key: $0, intentional: true) }
    deactivatePickerIfIdle()
  }

  func endAll() {
    let active = Array(entriesByWindowID.values)
    entriesByWindowID.removeAll()
    windowIDByKey.removeAll()
    pendingKeysByWindowID.removeAll()
    pendingWindowIDByKey.removeAll()
    windowIDByStream.removeAll()
    sinksBySession.removeAll()
    for entry in active { stop(entry, intentional: true) }
    ComputerUseRevocations.shared.clearAll()
    SCContentSharingPicker.shared.isActive = false
  }

  private func start(windowID: CGWindowID) async {
    defer { deactivatePickerIfIdle() }
    do {
      let content = try await SCShareableContent.current
      guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        clearPending(windowID: windowID)
        Log.computerUse.error(
          "Unable to start native sharing: window \(windowID, privacy: .public) is no longer shareable"
        )
        return
      }

      let filter = SCContentFilter(desktopIndependentWindow: window)
      let pointPixelScale = max(1, CGFloat(filter.pointPixelScale))
      let pendingSessions = Set((pendingKeysByWindowID[windowID] ?? []).map(\.sessionID))
      let settings = computerUseNativePreviewSettings(
        windowFrame: window.frame,
        pointPixelScale: pointPixelScale,
        viewerCount: viewerCount(sessions: pendingSessions),
        requestedDimension: requestedDimension(sessions: pendingSessions)
      )
      let stream = SCStream(
        filter: filter,
        configuration: computerUseNativePreviewConfiguration(settings),
        delegate: self
      )
      let publisher = ComputerUseFramePublisher()
      try stream.addStreamOutput(publisher, type: .screen, sampleHandlerQueue: outputQueue)

      var pickerConfiguration = SCContentSharingPickerConfiguration()
      pickerConfiguration.allowedPickerModes = .singleWindow
      pickerConfiguration.allowsChangingSelectedContent = false
      let picker = SCContentSharingPicker.shared
      picker.setConfiguration(pickerConfiguration, for: stream)
      picker.isActive = true

      try await stream.startCapture()

      let keys = takeValidPendingKeys(windowID: windowID)
      guard !keys.isEmpty else {
        picker.setConfiguration(nil, for: stream)
        try? await stream.stopCapture()
        return
      }

      let entry = Entry(
        windowID: windowID,
        stream: stream,
        publisher: publisher,
        keys: keys,
        pointPixelScale: pointPixelScale,
        settings: settings,
        windowFrame: window.frame
      )
      entriesByWindowID[windowID] = entry
      keys.forEach { windowIDByKey[$0] = windowID }
      windowIDByStream[ObjectIdentifier(stream)] = windowID
      resubscribe(windowID: windowID)
      watchForStall(stream: stream, publisher: publisher, windowID: windowID)
    } catch {
      clearPending(windowID: windowID)
      Log.computerUse.error(
        "Unable to start native sharing for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func refreshPreviewConfiguration(windowID: CGWindowID, windowFrame: CGRect) {
    guard var entry = entriesByWindowID[windowID] else { return }
    entry.windowFrame = windowFrame
    entriesByWindowID[windowID] = entry
    let sessions = Set(entry.keys.map(\.sessionID))
    apply(
      computerUseNativePreviewSettings(
        windowFrame: windowFrame,
        pointPixelScale: entry.pointPixelScale,
        viewerCount: viewerCount(sessions: sessions),
        requestedDimension: requestedDimension(sessions: sessions)
      ),
      windowID: windowID
    )
  }

  private func apply(_ desired: ComputerUseNativePreviewSettings, windowID: CGWindowID) {
    guard var entry = entriesByWindowID[windowID], desired != entry.settings else { return }
    if desired.size != entry.settings.size {
      for sink in entry.publisher.currentSinks { sink.prepare(size: desired.size) }
    }
    entry.settings = desired
    entriesByWindowID[windowID] = entry
    let stream = entry.stream
    let configuration = computerUseNativePreviewConfiguration(desired)
    Task { @MainActor [weak self] in
      do {
        try await stream.updateConfiguration(configuration)
        self?.reconcilePreviewConfiguration(
          windowID: windowID,
          stream: stream,
          applied: desired
        )
      } catch {
        Log.computerUse.error(
          "Unable to reconfigure native sharing preview for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  private func reconcilePreviewConfiguration(
    windowID: CGWindowID,
    stream: SCStream,
    applied: ComputerUseNativePreviewSettings
  ) {
    guard let entry = entriesByWindowID[windowID],
      ObjectIdentifier(entry.stream) == ObjectIdentifier(stream),
      entry.settings != applied
    else { return }
    let latest = entry.settings
    Task { @MainActor in
      do {
        try await stream.updateConfiguration(computerUseNativePreviewConfiguration(latest))
      } catch {
        Log.computerUse.error(
          "Unable to reconcile native sharing preview for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  // MARK: Live preview sinks

  func attachSink(sessionID: String, token: UUID, sink: any ComputerUseFrameSink) {
    sinksBySession[sessionID, default: [:]][token] = sink
    resubscribe(sessionID: sessionID)
  }

  func detachSink(sessionID: String, token: UUID) {
    guard sinksBySession[sessionID]?.removeValue(forKey: token) != nil else { return }
    if sinksBySession[sessionID]?.isEmpty == true { sinksBySession.removeValue(forKey: sessionID) }
    resubscribe(sessionID: sessionID)
  }

  /// The window was moved or resized outside a tool call. Resizes the
  /// stream when its output size changes; a no-op otherwise.
  func windowFrameChanged(windowID: CGWindowID, windowFrame: CGRect) {
    refreshPreviewConfiguration(windowID: windowID, windowFrame: windowFrame)
  }

  /// The size frames are currently delivered at for the session's window.
  func previewSize(sessionID: String) -> CGSize? {
    windowIDByKey.first { $0.key.sessionID == sessionID }
      .flatMap { entriesByWindowID[$0.value]?.settings.size }
  }

  func hasSinks(sessionID: String) -> Bool {
    sinksBySession[sessionID]?.isEmpty == false
  }

  private func resubscribe(sessionID: String) {
    let windowIDs = Set(windowIDByKey.filter { $0.key.sessionID == sessionID }.map(\.value))
    windowIDs.forEach { resubscribe(windowID: $0) }
  }

  private func viewerCount(sessions: Set<String>) -> Int {
    sessions.reduce(0) { $0 + (sinksBySession[$1]?.count ?? 0) }
  }

  private func requestedDimension(sessions: Set<String>) -> CGFloat {
    sessions.flatMap { sinksBySession[$0]?.values.map(\.requestedDimension) ?? [] }.max() ?? 0
  }

  /// A viewer now displays the preview at a different pixel size.
  func requestedDimensionChanged(sessionID: String) {
    let windowIDs = Set(windowIDByKey.filter { $0.key.sessionID == sessionID }.map(\.value))
    for windowID in windowIDs {
      guard let entry = entriesByWindowID[windowID] else { continue }
      refreshPreviewConfiguration(windowID: windowID, windowFrame: entry.windowFrame)
    }
  }

  /// Points the stream's publisher at the sinks of every session sharing
  /// the window, and matches its frame rate to whether anyone is watching.
  private func resubscribe(windowID: CGWindowID) {
    guard let entry = entriesByWindowID[windowID] else { return }
    var sinks: [UUID: any ComputerUseFrameSink] = [:]
    for sessionID in Set(entry.keys.map(\.sessionID)) {
      sinks.merge(sinksBySession[sessionID] ?? [:]) { current, _ in current }
    }
    let previous = Set(entry.publisher.currentSinks.map { ObjectIdentifier($0) })
    for sink in sinks.values where !previous.contains(ObjectIdentifier(sink)) {
      sink.prepare(size: entry.settings.size)
    }
    entry.publisher.setSinks(sinks)
    refreshPreviewConfiguration(windowID: windowID, windowFrame: entry.windowFrame)
  }

  private func detach(key: ComputerUseShareKey, intentional: Bool) {
    if let pendingWindowID = pendingWindowIDByKey.removeValue(forKey: key) {
      pendingKeysByWindowID[pendingWindowID]?.remove(key)
      if pendingKeysByWindowID[pendingWindowID]?.isEmpty == true {
        pendingKeysByWindowID.removeValue(forKey: pendingWindowID)
      }
    }

    guard let windowID = windowIDByKey.removeValue(forKey: key),
      var entry = entriesByWindowID[windowID]
    else { return }
    entry.keys.remove(key)
    if entry.keys.isEmpty {
      entriesByWindowID.removeValue(forKey: windowID)
      stop(entry, intentional: intentional)
    } else {
      entriesByWindowID[windowID] = entry
      resubscribe(windowID: windowID)
    }
  }

  private func takeValidPendingKeys(windowID: CGWindowID) -> Set<ComputerUseShareKey> {
    let pending = pendingKeysByWindowID.removeValue(forKey: windowID) ?? []
    let valid = pending.filter { key in
      pendingWindowIDByKey[key] == windowID
        && !ComputerUseRevocations.shared.contains(key)
    }
    for key in pending where pendingWindowIDByKey[key] == windowID {
      pendingWindowIDByKey.removeValue(forKey: key)
    }
    return Set(valid)
  }

  private func clearPending(windowID: CGWindowID) {
    let pending = pendingKeysByWindowID.removeValue(forKey: windowID) ?? []
    for key in pending where pendingWindowIDByKey[key] == windowID {
      pendingWindowIDByKey.removeValue(forKey: key)
    }
  }

  private func stop(_ entry: Entry, intentional: Bool) {
    let identifier = ObjectIdentifier(entry.stream)
    windowIDByStream.removeValue(forKey: identifier)
    entry.publisher.removeAll()
    SCContentSharingPicker.shared.setConfiguration(nil, for: entry.stream)
    if intentional { intentionallyStopping.insert(identifier) }
    Task { @MainActor [weak self] in
      do {
        try await entry.stream.stopCapture()
      } catch {
        Log.computerUse.error(
          "Unable to stop native sharing for window \(entry.windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
      self?.intentionallyStopping.remove(identifier)
      self?.deactivatePickerIfIdle()
    }
  }

  private func deactivatePickerIfIdle() {
    if entriesByWindowID.isEmpty && pendingKeysByWindowID.isEmpty {
      SCContentSharingPicker.shared.isActive = false
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let identifier = ObjectIdentifier(stream)
    let nsError = error as NSError
    let userStopped =
      nsError.domain == SCStreamErrorDomain
      && nsError.code == SCStreamError.userStopped.rawValue
    Task { @MainActor in
      guard !intentionallyStopping.contains(identifier),
        let windowID = windowIDByStream.removeValue(forKey: identifier),
        let entry = entriesByWindowID.removeValue(forKey: windowID)
      else { return }

      entry.publisher.removeAll()
      entry.keys.forEach { windowIDByKey.removeValue(forKey: $0) }
      if userStopped {
        // Transient: the system reports its own stream teardown the
        // same way it reports a Control Center stop, so this cannot
        // be treated as a lasting decision.
        for key in entry.keys {
          ComputerUseRevocations.shared.insertTransient(key)
          ComputerUsePresentationState.shared.systemStopped(key: key)
        }
      } else {
        // The window vanished (target quit or closed the shared
        // window). Tear the presentation and menu-bar entry down, but
        // do not revoke: a fresh window may be reattached later.
        Log.computerUse.error(
          "Native sharing stopped unexpectedly for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        for key in entry.keys {
          ComputerUsePresentationState.shared.systemStopped(key: key)
        }
      }
      deactivatePickerIfIdle()
    }
  }

  nonisolated func contentSharingPicker(
    _ picker: SCContentSharingPicker,
    didCancelFor stream: SCStream?
  ) {}

  nonisolated func contentSharingPicker(
    _ picker: SCContentSharingPicker,
    didUpdateWith filter: SCContentFilter,
    for stream: SCStream?
  ) {
    guard let stream else { return }
    let streamBox = ComputerUseUncheckedSendable(value: stream)
    let filterBox = ComputerUseUncheckedSendable(value: filter)
    Task { @MainActor [weak self, streamBox, filterBox] in
      guard let self else { return }
      let stream = streamBox.value
      let identifier = ObjectIdentifier(stream)
      guard self.windowIDByStream[identifier] != nil else { return }
      do {
        try await stream.updateContentFilter(filterBox.value)
      } catch {
        Log.computerUse.error(
          "Unable to apply native sharing picker update: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
    Log.computerUse.error(
      "Native sharing picker failed: \(error.localizedDescription, privacy: .public)"
    )
  }
}

extension ComputerUseNativeSharing {
  /// A preview stream that starts and never calls back is what an exhausted `replayd` looks like
  /// (on this Mac: 246 pipes, and the PiP sat on "Starting…"). Screen sharing's recovery restarts
  /// the stream, then the daemon (at most once per 10 minutes, shared with screen sharing), then
  /// the stream again. It gives up quietly if the window's stream is replaced or stopped meanwhile.
  fileprivate func watchForStall(stream: SCStream, publisher: ComputerUseFramePublisher, windowID: CGWindowID) {
    let recovery = ScreenSharingCaptureStallRecovery.live(
      metrics: ScreenSharingMetrics(), callbacks: { publisher.callbacks },
      restartCapture: { [weak self] in
        guard let self, self.entriesByWindowID[windowID]?.stream === stream else { throw CancellationError() }
        try? await stream.stopCapture()
        try await stream.startCapture()
      },
      log: { Log.computerUse.notice("\($0, privacy: .public)") },
      onStalled: {
        Log.computerUse.notice("Live preview for window \(windowID, privacy: .public) delivered nothing; recovering")
      })
    Task { @MainActor in
      let outcome = try? await recovery.run(baseline: 0)
      if outcome == .failed {
        Log.computerUse.error("Live preview for window \(windowID, privacy: .public) never delivered a frame")
      }
    }
  }
}

/// Which session/app pairings may not be controlled right now.
///
/// Two kinds, because they mean different things. Choosing "Stop Using X" in
/// the menu bar is an unambiguous decision and holds for the session. A
/// ScreenCaptureKit stream ending is not: the system stops streams for its
/// own reasons (window churn, stream limits), and treating that as a decision
/// stranded healthy sessions with no way back. Those are transient — the next
/// deliberate `get_app_state` clears them, so an agent that follows the error
/// message recovers, while an action fired blindly still fails.
final class ComputerUseRevocations: @unchecked Sendable {
  static let shared = ComputerUseRevocations()

  private let lock = NSLock()
  private var permanent: Set<ComputerUseShareKey> = []
  private var transient: Set<ComputerUseShareKey> = []

  func contains(_ key: ComputerUseShareKey) -> Bool {
    lock.withLock { permanent.contains(key) || transient.contains(key) }
  }

  func isPermanent(_ key: ComputerUseShareKey) -> Bool {
    lock.withLock { permanent.contains(key) }
  }

  /// The user chose to stop this app from the menu bar.
  func insert(_ key: ComputerUseShareKey) {
    _ = lock.withLock { permanent.insert(key) }
  }

  /// The system stopped the sharing stream; recoverable on re-observation.
  func insertTransient(_ key: ComputerUseShareKey) {
    _ = lock.withLock { transient.insert(key) }
  }

  /// Called when a session deliberately re-observes the app.
  func clearTransient(_ key: ComputerUseShareKey) {
    _ = lock.withLock { transient.remove(key) }
  }

  func clear(sessionID: String) {
    lock.withLock {
      permanent = permanent.filter { $0.sessionID != sessionID }
      transient = transient.filter { $0.sessionID != sessionID }
    }
  }

  func clearAll() {
    lock.withLock {
      permanent.removeAll()
      transient.removeAll()
    }
  }
}

/// The preview stream's capture settings.
func computerUseNativePreviewConfiguration(
  _ settings: ComputerUseNativePreviewSettings
) -> SCStreamConfiguration {
  let configuration = SCStreamConfiguration()
  configuration.width = Int(settings.size.width)
  configuration.height = Int(settings.size.height)
  configuration.minimumFrameInterval = CMTime(
    value: 1,
    timescale: settings.framesPerSecond
  )
  configuration.queueDepth = ComputerUseNativePreviewMetrics.queueDepth
  configuration.showsCursor = false
  configuration.capturesAudio = false
  configuration.scalesToFit = true
  configuration.ignoreShadowsSingleWindow = true
  // BGRA, not SCK's 4:2:0 default: UI text stays crisp, and the alpha
  // channel tells the PiP where the window's padding and corners are.
  configuration.pixelFormat = kCVPixelFormatType_32BGRA
  return configuration
}
