import AppKit
import Foundation
import ScreenCaptureKit

final class ComputerUseRecordings: @unchecked Sendable {
  let directory: URL
  private let lock = NSLock()
  private var entries: [String: ComputerUseRecording] = [:]
  private var startingSessions: [String: UUID] = [:]

  init(directory: URL) { self.directory = directory }

  private func content() throws -> SCShareableContent {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      throw BridgeError("Enable Screen Recording for Codevisor in System Settings → Privacy & Security.")
    }
    let result = ComputerUseRecordingResult<SCShareableContent>()
    Task {
      do {
        result.complete(
          .success(try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)))
      } catch { result.complete(.failure(error)) }
    }
    return try result.wait()
  }

  private func isProtected(_ app: SCRunningApplication?) -> Bool {
    guard let app else { return false }
    return computerUseApplicationIsProtected(
      .init(id: app.bundleIdentifier, displayName: app.applicationName, path: ""))
  }

  func targets() throws -> [String: Any] {
    let content = try content()
    return [
      "windows": content.windows.filter { $0.windowLayer == 0 && !isProtected($0.owningApplication) }.map { window in
        [
          "windowId": window.windowID, "title": window.title ?? "",
          "app": window.owningApplication?.bundleIdentifier ?? "",
          "appName": window.owningApplication?.applicationName ?? "", "width": window.frame.width,
          "height": window.frame.height,
          "onScreen": window.isOnScreen,
        ] as [String: Any]
      },
      "displays": content.displays.map { display in
        [
          "displayId": display.displayID, "width": display.width, "height": display.height,
          "isMain": display.displayID == CGMainDisplayID(), "x": display.frame.minX, "y": display.frame.minY,
        ] as [String: Any]
      },
    ]
  }

  func start(sessionID: String, agentLabel: String?, arguments: [String: Any]) throws -> [String: Any] {
    guard !sessionID.isEmpty else { throw BridgeError("A session is required to record.") }
    let options = try ComputerUseRecordingOptions(arguments)
    let reservation = UUID()
    try lock.withLock {
      guard startingSessions[sessionID] == nil,
        !entries.values.contains(where: { $0.sessionID == sessionID && !$0.isFinished })
      else {
        throw BridgeError("This session already has an active recording. Use recording_status and stop it first.")
      }
      startingSessions[sessionID] = reservation
    }
    defer {
      lock.withLock {
        if startingSessions[sessionID] == reservation { startingSessions.removeValue(forKey: sessionID) }
      }
    }
    let content = try content()
    let filter: SCContentFilter
    let target: [String: Any]
    let sourceSize: CGSize
    let title: String
    if let id = options.windowID {
      guard let window = content.windows.first(where: { $0.windowID == id }), !isProtected(window.owningApplication)
      else {
        throw BridgeError("The recording window is unavailable. Call list_recording_targets again.")
      }
      if let app = window.owningApplication {
        try ComputerUsePresentation.requireControlAllowed(sessionID: sessionID, pid: app.processID)
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
      sourceSize = CGSize(
        width: window.frame.width * CGFloat(filter.pointPixelScale),
        height: window.frame.height * CGFloat(filter.pointPixelScale))
      title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.owningApplication?.applicationName ?? "Window"
      target = ["kind": "window", "windowId": id, "title": title]
    } else {
      guard let display = content.displays.first(where: { $0.displayID == options.displayID }) else {
        throw BridgeError("The recording display is unavailable. Call list_recording_targets again.")
      }
      filter = SCContentFilter(
        display: display, excludingApplications: content.applications.filter(isProtected), exceptingWindows: [])
      sourceSize = CGSize(width: display.width, height: display.height)
      title = "Display \(display.displayID)"
      target = ["kind": "display", "displayId": display.displayID, "title": title]
    }
    let size = try computerUseRecordingSize(sourceSize, maximumDimension: options.maximumDimension)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let recording = ComputerUseRecording(
      sessionID: sessionID, target: target, options: options, size: size, directory: directory)
    recording.onFinish = { [id = recording.id] in
      Task { @MainActor in ComputerUseRecordingStatusItem.shared.remove(id) }
    }
    try lock.withLock {
      guard startingSessions[sessionID] == reservation else {
        throw BridgeError("Recording cancelled because the session closed.")
      }
      let completed = entries.values.filter { $0.sessionID == sessionID && $0.isFinished }
      for old in completed.prefix(max(0, completed.count - 19)) { entries.removeValue(forKey: old.id) }
      entries[recording.id] = recording
    }
    do { try recording.start(filter: filter) } catch { recording.fail(error); throw error }
    Task { @MainActor in
      guard !recording.isFinished else { return }
      ComputerUseRecordingStatusItem.shared.add(recording, title: title, agentLabel: agentLabel)
    }
    return recording.metadata()
  }

  func status(sessionID: String, id: String?) throws -> [String: Any] {
    if let id { return try recording(sessionID: sessionID, id: id).metadata() }
    let records = lock.withLock { entries.values.filter { $0.sessionID == sessionID } }
    return ["recordings": records.sorted { $0.id < $1.id }.map { $0.metadata() }]
  }

  func stop(sessionID: String, id: String) throws -> [String: Any] {
    let recording = try recording(sessionID: sessionID, id: id)
    try recording.stop()
    return recording.metadata()
  }

  private func recording(sessionID: String, id: String) throws -> ComputerUseRecording {
    guard let recording = lock.withLock({ entries[id] }), recording.sessionID == sessionID else {
      throw BridgeError("Unknown recording in this session. Use recording_status to list its recordings.")
    }
    return recording
  }

  func end(sessionID: String? = nil) {
    let active = lock.withLock {
      if let sessionID { startingSessions.removeValue(forKey: sessionID) } else { startingSessions.removeAll() }
      return entries.values.filter { (sessionID == nil || $0.sessionID == sessionID) && !$0.isFinished }
    }
    for recording in active {
      DispatchQueue.global(qos: .utility).async { try? recording.stop(reason: "session_closed") }
    }
  }
}
