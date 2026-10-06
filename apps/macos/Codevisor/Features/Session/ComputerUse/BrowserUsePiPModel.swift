//  Drives the picture-in-picture preview of the browser tab a chat's agent
//  drives through Browser Use. The chat's server streams the tab, whichever
//  browser it lives in; this model decides when the card shows.

import CodevisorCore
import CodevisorCoreMac
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class BrowserUsePiPModel {
  /// A dismissal lasts until the agent stops using the browser and starts
  /// again, as with the Computer Use preview.
  private static var dismissedSessions: Set<UUID> = []
  private static var cornerBySession: [UUID: ComputerUseLivePreviewCorner] = [:]
  private static var areaBySession: [UUID: CGFloat] = [:]
  private static var lastArea: CGFloat?

  let chatSessionID: UUID
  private let connection: LivePreviewConnection
  private(set) var viewer: ComputerUseLivePreviewViewer?
  private(set) var isDismissed: Bool
  var corner: ComputerUseLivePreviewCorner {
    didSet { Self.cornerBySession[chatSessionID] = corner }
  }
  var area: CGFloat? {
    didSet {
      Self.areaBySession[chatSessionID] = area
      if let area { Self.lastArea = area }
    }
  }
  /// True from a stop until the hide delay elapses, so the card shows the
  /// stopped state briefly instead of vanishing mid-glance.
  private(set) var isLingering = false
  @ObservationIgnored private var hideTask: Task<Void, Never>?

  /// Cheap: connects only once the card appears.
  init(chatSessionID: UUID, client: any CodevisorServerClienting) {
    self.chatSessionID = chatSessionID
    connection = LivePreviewConnection(client: client, chatSession: chatSessionID)
    isDismissed = Self.dismissedSessions.contains(chatSessionID)
    corner = Self.cornerBySession[chatSessionID] ?? .topTrailing
    area = Self.areaBySession[chatSessionID] ?? Self.lastArea
  }

  private var state: LivePreviewConnection.State {
    connection.status?.state ?? .inactive
  }

  /// The tool the agent touched last, Browser Use or Computer Use.
  var lastUsedTool: LivePreviewConnection.Tool? { connection.lastUsedTool }

  /// Stops frames while another view has the card, keeping this one ready.
  func setPaused(_ paused: Bool) {
    connection.isPaused = paused
  }
}

extension BrowserUsePiPModel: LivePreviewPiPModel {
  var changeKey: LivePreviewConnection.Status? { connection.status }

  var isVisible: Bool {
    guard !isDismissed, viewer != nil else { return false }
    switch state {
    case .active, .idle: return true
    case .stopped: return isLingering
    case .inactive: return false
    }
  }

  var title: String {
    if let title = connection.status?.title, !title.isEmpty { return title }
    if let url = connection.status?.url, let host = URL(string: url)?.host, !host.isEmpty { return host }
    return "Browser"
  }

  var tint: Color { .accentColor }
  /// The agent's pointer is drawn into the page, so it's already in the frames.
  var cursor: CGPoint? { nil }
  var cursorWindowWidth: CGFloat { 0 }
  var showsTarget: Bool { false }
  var canActivateTarget: Bool { false }
  var hasCustomSize: Bool { area != nil }

  var isLive: Bool {
    state == .active && connection.isConnected && viewer?.frameSize != nil
  }

  var statusText: String? {
    guard let viewer else { return nil }
    if !connection.isConnected { return "Reconnecting…" }
    switch state {
    case .active: return viewer.frameSize == nil ? "Starting…" : nil
    case .idle: return "Idle"
    case .stopped, .inactive: return "Stopped"
    }
  }

  var canReload: Bool { viewer != nil && state == .active }

  func appeared(isTurnRunning: Bool) {
    connection.start()
    sync()
  }

  func sync() {
    // Once the closed activity goes idle or stops, the agent's next use of
    // the browser is a new request for attention.
    if state != .active, isDismissed {
      isDismissed = false
      Self.dismissedSessions.remove(chatSessionID)
    }
    switch state {
    case .active, .idle:
      hideTask?.cancel()
      hideTask = nil
      isLingering = false
      guard !isDismissed, viewer == nil, state == .active else {
        viewer?.update(title: title)
        return
      }
      viewer = connection.makeViewer(title: title)
    case .stopped:
      guard viewer != nil, hideTask == nil else { return }
      isLingering = true
      hideTask = Task { [weak self] in
        try? await Task.sleep(for: ComputerUsePiPModel.hideDelay)
        guard !Task.isCancelled, let self else { return }
        self.isLingering = false
        self.releaseViewer()
        self.hideTask = nil
      }
    case .inactive:
      releaseViewer()
    }
  }

  func turnActivityChanged(isRunning: Bool) {}

  func teardown() {
    hideTask?.cancel()
    hideTask = nil
    isLingering = false
    releaseViewer()
    connection.stop()
  }

  func dismiss() {
    isDismissed = true
    Self.dismissedSessions.insert(chatSessionID)
    releaseViewer()
  }

  func activateTarget() {}

  /// Recovers a frozen or blank preview: a fresh viewer asks the server to
  /// restart the tab's screencast.
  func reload() {
    guard canReload else { return }
    releaseViewer()
    viewer = connection.makeViewer(title: title)
  }

  func resetSize() {
    area = nil
    Self.lastArea = nil
  }

  private func releaseViewer() {
    viewer?.detach()
    viewer = nil
  }
}
