import AppKit
import CodevisorCore
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class ComputerUsePresentationState: NSObject {
  static let shared = ComputerUsePresentationState()

  struct SessionPresentation {
    var pid: pid_t
    var targetWindowID: CGWindowID?
    var cursorPanel: ComputerUseCursorPanel
    var cursorView: ComputerUseCursorView
    var colorIndex: Int
    var displayedTip: CGPoint?
    var idleTimer: Timer?
    var idlePhase: CGFloat
  }

  let cursorSize = ComputerUseCursorMetrics.windowSize
  let cursorTipAnchor = ComputerUseCursorMetrics.tipAnchor
  var sessions: [String: SessionPresentation] = [:]
  private var colorIndexBySession: [String: Int] = [:]
  /// When each session last drove the app, for idle release.
  private var lastActivityBySession: [String: Date] = [:]
  var visibilityTimer: Timer?

  private override init() {
    super.init()
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(activeSpaceDidChange(_:)),
      name: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(frontmostApplicationDidChange(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
    // Without this, a controlled app that quits leaves its menu-bar entry,
    // cursor panel, and 4 Hz visibility poll behind forever.
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(applicationDidTerminate(_:)),
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil
    )
  }

  func activate(
    sessionID: String,
    agentLabel: String?,
    appName: String,
    pid: pid_t,
    windowID: CGWindowID?,
    windowFrame: CGRect
  ) {
    guard !sessionID.isEmpty else { return }
    lastActivityBySession[sessionID] = Date()
    let targetWindowID = windowID ?? matchingWindow(pid: pid, frame: windowFrame)
    let colorIndex = colorIndex(for: sessionID)

    if var presentation = sessions[sessionID] {
      if presentation.pid != pid {
        // The session re-attached to a different process (a rebuilt
        // dev app is the common case). Retire the old pid's menu-bar
        // entry and sharing key or they would linger as duplicates.
        let staleKey = ComputerUseShareKey(sessionID: sessionID, pid: presentation.pid)
        ComputerUseControlStatusItem.shared.remove(key: staleKey)
        ComputerUseNativeSharing.shared.retire(key: staleKey)
      }
      presentation.pid = pid
      presentation.targetWindowID = targetWindowID
      presentation.colorIndex = colorIndex
      presentation.cursorView.tint = ComputerUseCursorPalette.color(at: colorIndex)
      sessions[sessionID] = presentation
    } else {
      let panel = ComputerUseCursorPanel(
        contentRect: CGRect(origin: .zero, size: cursorSize),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      configureCursorPanel(panel)
      let view = ComputerUseCursorView(frame: CGRect(origin: .zero, size: cursorSize))
      view.autoresizingMask = [.width, .height]
      view.tint = ComputerUseCursorPalette.color(at: colorIndex)
      panel.contentView = view
      sessions[sessionID] = SessionPresentation(
        pid: pid,
        targetWindowID: targetWindowID,
        cursorPanel: panel,
        cursorView: view,
        colorIndex: colorIndex,
        displayedTip: nil,
        idleTimer: nil,
        idlePhase: 0
      )
    }

    ComputerUseControlStatusItem.shared.activate(
      key: ComputerUseShareKey(sessionID: sessionID, pid: pid),
      appName: appName,
      agentLabel: agentLabel,
      colorIndex: colorIndex
    )

    ComputerUseNativeSharing.shared.activate(
      sessionID: sessionID,
      pid: pid,
      windowID: targetWindowID,
      windowFrame: windowFrame
    )
    startVisibilityMonitoringIfNeeded()
    refreshCursorVisibility()
  }

  func moveCursor(sessionID: String, to screenStatePoint: CGPoint, pulse: Bool) {
    lastActivityBySession[sessionID] = Date()
    guard var presentation = sessions[sessionID] else { return }
    presentation.idleTimer?.invalidate()
    presentation.idleTimer = nil
    let target = appKitPoint(fromScreenStatePoint: screenStatePoint)
    let targetIsVisible = cursorShouldBeVisible(presentation)

    if targetIsVisible {
      order(presentation.cursorPanel, relativeTo: presentation.targetWindowID)
      if pulse {
        if presentation.displayedTip != target {
          animateMove(presentation: &presentation, sessionID: sessionID, to: target)
        }
        animateClick(presentation: presentation, at: target)
      } else {
        animateMove(presentation: &presentation, sessionID: sessionID, to: target)
      }
    } else {
      presentation.cursorPanel.orderOut(nil)
      presentation.cursorView.clickProgress = 0
      place(presentation: presentation, tip: target, rotation: 0, bodyOffset: .zero)
    }
    // The animations above pump the run loop, so another session's work —
    // or this session's own end/stop — may have run reentrantly. Writing
    // the stale copy back would resurrect a removed session's cursor.
    guard sessions[sessionID] != nil else {
      presentation.idleTimer?.invalidate()
      presentation.cursorPanel.orderOut(nil)
      return
    }
    presentation.displayedTip = target
    sessions[sessionID] = presentation
    if targetIsVisible {
      startIdleAnimation(sessionID: sessionID)
    }
  }

  func systemStopped(key: ComputerUseShareKey) {
    ComputerUseControlStatusItem.shared.remove(key: key)
    if let presentation = sessions[key.sessionID], presentation.pid == key.pid {
      presentation.idleTimer?.invalidate()
      presentation.cursorPanel.orderOut(nil)
      sessions.removeValue(forKey: key.sessionID)
      lastActivityBySession.removeValue(forKey: key.sessionID)
    }
    stopVisibilityMonitoringIfNeeded()
  }

  /// The user chose "Stop Using …" for one agent's control of one app.
  /// Revokes exactly that session/app pairing; other agents keep going.
  func stopUsing(key: ComputerUseShareKey) {
    ComputerUseRevocations.shared.insert(key)
    if let presentation = sessions[key.sessionID], presentation.pid == key.pid {
      presentation.idleTimer?.invalidate()
      presentation.cursorPanel.orderOut(nil)
      sessions.removeValue(forKey: key.sessionID)
      lastActivityBySession.removeValue(forKey: key.sessionID)
    }
    ComputerUseControlStatusItem.shared.remove(key: key)
    ComputerUseNativeSharing.shared.retire(key: key)
    stopVisibilityMonitoringIfNeeded()
  }

  /// The controlled app exited. Unlike `stopUsing`, nothing is revoked: the
  /// quit was not a user decision about Computer Use, and the same session
  /// may legitimately control a relaunched instance.
  func targetTerminated(pid: pid_t) {
    let sessionIDs = sessions.filter { $0.value.pid == pid }.map(\.key)
    for sessionID in sessionIDs {
      if let presentation = sessions.removeValue(forKey: sessionID) {
        presentation.idleTimer?.invalidate()
        presentation.cursorPanel.orderOut(nil)
      }
      lastActivityBySession.removeValue(forKey: sessionID)
    }
    ComputerUseControlStatusItem.shared.remove(pid: pid)
    ComputerUseNativeSharing.shared.targetTerminated(pid: pid)
    stopVisibilityMonitoringIfNeeded()
  }

  /// Drops the share, cursor and menu bar entry of a session that has gone
  /// quiet, without ending it: the next tool call re-attaches implicitly,
  /// keeping the same cursor colour, and any revocation still stands.
  private func releaseIdle(sessionID: String) {
    if let presentation = sessions.removeValue(forKey: sessionID) {
      presentation.idleTimer?.invalidate()
      presentation.cursorPanel.orderOut(nil)
    }
    lastActivityBySession.removeValue(forKey: sessionID)
    ComputerUseControlStatusItem.shared.remove(sessionID: sessionID)
    ComputerUseNativeSharing.shared.release(sessionID: sessionID)
    stopVisibilityMonitoringIfNeeded()
  }

  func releaseIdleSessions() {
    for sessionID in computerUseIdleSessions(
      lastActivity: lastActivityBySession,
      now: Date()
    ) {
      Log.computerUse.log(
        "Releasing idle Computer Use attachment for session \(sessionID, privacy: .public)"
      )
      releaseIdle(sessionID: sessionID)
    }
  }

  func end(sessionID: String) {
    if let presentation = sessions.removeValue(forKey: sessionID) {
      presentation.idleTimer?.invalidate()
      presentation.cursorPanel.orderOut(nil)
    }
    colorIndexBySession.removeValue(forKey: sessionID)
    lastActivityBySession.removeValue(forKey: sessionID)
    ComputerUseControlStatusItem.shared.remove(sessionID: sessionID)
    ComputerUseNativeSharing.shared.end(sessionID: sessionID)
    stopVisibilityMonitoringIfNeeded()
  }

  func endAll() {
    for presentation in sessions.values {
      presentation.idleTimer?.invalidate()
      presentation.cursorPanel.orderOut(nil)
    }
    sessions.removeAll()
    colorIndexBySession.removeAll()
    lastActivityBySession.removeAll()
    visibilityTimer?.invalidate()
    visibilityTimer = nil
    ComputerUseControlStatusItem.shared.removeAll()
    ComputerUseNativeSharing.shared.endAll()
  }

  /// Keeps the assignment stable for a session's whole lifetime while
  /// steering concurrent sessions away from one another's colors.
  private func colorIndex(for sessionID: String) -> Int {
    if let existing = colorIndexBySession[sessionID] { return existing }
    let taken = Set(sessions.keys.compactMap { colorIndexBySession[$0] })
    let index = computerUseCursorColorIndex(sessionID: sessionID, takenIndices: taken)
    colorIndexBySession[sessionID] = index
    return index
  }
}
