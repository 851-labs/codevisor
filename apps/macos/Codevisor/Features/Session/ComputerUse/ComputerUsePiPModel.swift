//  Drives the picture-in-picture preview of the window a chat's agent is
//  controlling through Computer Use. Local chats watch the in-process
//  stream; chats on another Mac watch it over screen sharing. The viewer
//  owns the frame source and must always be detached.

import AppKit
import CodevisorCore
import CodevisorCoreMac
import Foundation
import Observation
import os
import SwiftUI

/// The chat pane a live view is shown in; a remote host checks that the
/// pane really shows this chat before streaming to it.
struct ComputerUsePiPPane: Equatable {
  let workspaceId: UUID
  let paneId: UUID
}

extension EnvironmentValues {
  @Entry var computerUsePiPPane: ComputerUsePiPPane?
}

@MainActor
@Observable
final class ComputerUsePiPModel {
  enum Source {
    case local
    case remote(client: any CodevisorServerClienting, pane: ComputerUsePiPPane)
  }

  /// Dismissals survive tab switches and turns, but not new Computer Use
  /// activity: the preview returns once the agent has stopped (or gone
  /// idle) and then controls an app again.
  private static var dismissedSessions: Set<UUID> = []
  /// Where the user last left each session's card; survives tab switches.
  private static var cornerBySession: [UUID: ComputerUseLivePreviewCorner] = [:]
  /// The card area the user last chose in each session, and anywhere: a new
  /// chat starts at the size the user last settled on.
  private static var areaBySession: [UUID: CGFloat] = [:]
  private static var lastArea: CGFloat?

  static let hideDelay: Duration = .seconds(2)

  let chatSessionID: UUID
  private let source: Source
  private let preview: ComputerUseLivePreview
  private(set) var viewer: ComputerUseLivePreviewViewer?
  private(set) var isDismissed: Bool
  var corner: ComputerUseLivePreviewCorner {
    didSet { Self.cornerBySession[chatSessionID] = corner }
  }
  /// The preferred card area in square points; nil until the user resizes,
  /// meaning the default fit.
  var area: CGFloat? {
    didSet {
      Self.areaBySession[chatSessionID] = area
      if let area { Self.lastArea = area }
    }
  }
  /// Local only: true from a stop until the hide delay elapses, so the card
  /// shows the stopped state briefly instead of vanishing mid-glance.
  private(set) var isLingering = false
  @ObservationIgnored private var hideTask: Task<Void, Never>?
  /// Remote only: while dismissed, asks the host (without streaming) for
  /// the agent's next activity.
  @ObservationIgnored private var reappearanceTask: Task<Void, Never>?
  @ObservationIgnored private var prefersFastPolling = false

  /// `preview` defaults to the shared facade. It is resolved here rather
  /// than as a default argument, which would be evaluated off the main actor.
  init(chatSessionID: UUID, source: Source, preview: ComputerUseLivePreview? = nil) {
    self.chatSessionID = chatSessionID
    self.source = source
    self.preview = preview ?? .shared
    isDismissed = Self.dismissedSessions.contains(chatSessionID)
    corner = Self.cornerBySession[chatSessionID] ?? .topTrailing
    area = Self.areaBySession[chatSessionID] ?? Self.lastArea
  }

  var isRemote: Bool {
    if case .remote = source { return true }
    return false
  }

  /// Local activity; nil for remote chats.
  var activity: ComputerUseLivePreview.Activity? {
    isRemote ? nil : preview.activity(forChatSession: chatSessionID)
  }

  // MARK: Presentation

  var isVisible: Bool {
    guard !isDismissed, let viewer else { return false }
    if isRemote {
      switch viewer.phase {
      case .searching: return false
      case .connecting, .live, .reconnecting, .stopped: return true
      }
    }
    guard let activity else { return false }
    return activity.state != .stopped || isLingering
  }

  var title: String {
    activity?.appName ?? viewer?.title ?? ""
  }

  var tint: Color {
    activity.map { Color(nsColor: $0.tint) } ?? .accentColor
  }

  var isLive: Bool {
    guard let viewer, viewer.phase == .live else { return false }
    return isRemote || activity?.state == .active
  }

  /// The agent cursor as a 0…1 fraction of the frame, when known.
  var cursor: CGPoint? {
    isLive ? activity?.cursor : nil
  }

  var statusText: String? {
    guard let viewer else { return nil }
    switch viewer.phase {
    case .searching, .connecting: return "Connecting…"
    case .reconnecting: return "Reconnecting…"
    case .stopped(let message): return message
    case .live: break
    }
    guard let activity else { return viewer.frameSize == nil ? "Starting…" : nil }
    switch activity.state {
    case .active: return viewer.frameSize == nil ? "Starting…" : nil
    case .idle: return "Idle"
    case .stopped: return "Stopped"
    }
  }

  var canActivateTarget: Bool { activity != nil }

  /// Refresh applies to a preview that is showing, or trying to show, live
  /// frames: not once it has stopped.
  var canReload: Bool {
    guard let viewer else { return false }
    if isRemote {
      if case .stopped = viewer.phase { return false }
      return true
    }
    return activity?.state == .active
  }

  /// Whether the user has resized the card away from the default fit.
  var hasCustomSize: Bool { area != nil }

  // MARK: Lifecycle

  /// The card's view appeared, e.g. on a tab or chat switch, possibly
  /// mid-turn. A dismissed preview stays dismissed.
  func appeared(isTurnRunning: Bool) {
    Log.computerUse.debug(
      "Live view \(self.chatSessionID, privacy: .public): appeared (remote=\(self.isRemote), dismissed=\(self.isDismissed), turn running=\(isTurnRunning))"
    )
    turnActivityChanged(isRunning: isTurnRunning)
    sync()
  }

  /// Reconciles the viewer with the current state. Call on appear and
  /// whenever local activity changes.
  func sync() {
    switch source {
    case .local: syncLocal()
    case .remote:
      if isDismissed {
        watchForRemoteActivity()
        return
      }
      guard viewer == nil else { return }
      viewer = makeViewer()
    }
  }

  /// Recovers a frozen or blank preview without closing the card: a fresh
  /// viewer re-attaches to the stream, which reconfigures for it.
  func reload() {
    guard canReload else { return }
    viewer = ComputerUseLivePreview.replace(viewer) { makeViewer() }
  }

  /// Back to the default fit, here and for chats that open later.
  func resetSize() {
    area = nil
    Self.lastArea = nil
  }

  /// The chat's turn started or finished. A running turn makes a remote
  /// viewer look more often; it doesn't bring back a dismissed preview.
  func turnActivityChanged(isRunning: Bool) {
    if isRunning != prefersFastPolling {
      Log.computerUse.debug(
        "Live view \(self.chatSessionID, privacy: .public): turn running=\(isRunning), dismissed=\(self.isDismissed)")
    }
    prefersFastPolling = isRunning
    viewer?.prefersFastPolling = isRunning
  }

  func dismiss() {
    Log.computerUse.log(
      "Live view \(self.chatSessionID, privacy: .public): closed (remote=\(self.isRemote), visible=\(self.isVisible))")
    isDismissed = true
    Self.dismissedSessions.insert(chatSessionID)
    releaseViewer()
    if isRemote { watchForRemoteActivity() }
  }

  func activateTarget() {
    guard let pid = activity?.pid else { return }
    NSRunningApplication(processIdentifier: pid)?.activate()
  }

  func teardown() {
    hideTask?.cancel()
    hideTask = nil
    reappearanceTask?.cancel()
    reappearanceTask = nil
    isLingering = false
    releaseViewer()
  }

  /// New Computer Use activity: a dismissed preview may show again.
  private func undismiss(reason: String) {
    guard isDismissed else { return }
    Log.computerUse.log("Live view \(self.chatSessionID, privacy: .public): reopens, \(reason, privacy: .public)")
    isDismissed = false
    Self.dismissedSessions.remove(chatSessionID)
  }

  /// Polls the host until the agent has stopped controlling an app and then
  /// controls one again, which brings the dismissed preview back. The
  /// activity the user closed doesn't: it must be seen to end first. A host
  /// that can't answer leaves the preview closed.
  private func watchForRemoteActivity() {
    guard reappearanceTask == nil, case .remote(let client, let pane) = source else { return }
    let preview = preview
    let chatSessionID = chatSessionID
    reappearanceTask = Task { [weak self] in
      var sawNoActivity = false
      while !Task.isCancelled {
        let active = await preview.remoteActivityIsActive(
          chatSession: chatSessionID, client: client, workspaceId: pane.workspaceId, paneId: pane.paneId)
        guard !Task.isCancelled,
          let interval = self?.remoteActivityObserved(active, sawNoActivity: &sawNoActivity)
        else { return }
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// One answer from the host while dismissed. Returns how long to wait
  /// before asking again, or nil once the watch is over.
  private func remoteActivityObserved(_ active: Bool?, sawNoActivity: inout Bool) -> Duration? {
    guard isDismissed else {
      reappearanceTask = nil
      return nil
    }
    if active == false { sawNoActivity = true }
    if active == true, sawNoActivity {
      reappearanceTask = nil
      undismiss(reason: "the agent controls an app again")
      sync()
      return nil
    }
    return ComputerUseLivePreview.remotePollInterval(prefersFastPolling: prefersFastPolling)
  }

  private func syncLocal() {
    guard let activity else {
      teardown()
      return
    }
    // Once the closed activity goes idle or stops, the agent's next use of
    // an app is a new request for attention.
    if activity.state != .active { undismiss(reason: "the activity went \(activity.state)") }
    switch activity.state {
    case .active, .idle:
      hideTask?.cancel()
      hideTask = nil
      isLingering = false
      guard !isDismissed, viewer == nil, activity.state == .active else { return }
      viewer = makeViewer()
    case .stopped:
      guard viewer != nil, hideTask == nil else { return }
      isLingering = true
      hideTask = Task { [weak self] in
        try? await Task.sleep(for: Self.hideDelay)
        guard !Task.isCancelled, let self else { return }
        self.isLingering = false
        self.releaseViewer()
        self.hideTask = nil
      }
    }
  }

  private func makeViewer() -> ComputerUseLivePreviewViewer? {
    switch source {
    case .local:
      return preview.makeLocalViewer(chatSession: chatSessionID)
    case .remote(let client, let pane):
      let viewer = preview.makeRemoteViewer(
        chatSession: chatSessionID, client: client, workspaceId: pane.workspaceId, paneId: pane.paneId)
      viewer.prefersFastPolling = prefersFastPolling
      return viewer
    }
  }

  private func releaseViewer() {
    viewer?.detach()
    viewer = nil
  }
}
