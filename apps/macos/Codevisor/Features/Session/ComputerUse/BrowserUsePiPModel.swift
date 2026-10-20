import CodevisorCore
import CodevisorCoreMac
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class BrowserUsePiPModel {
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

  var lastUsedTool: LivePreviewConnection.Tool? { connection.lastUsedTool }

  func setPaused(_ paused: Bool) {
    connection.isPaused = paused
  }
}

extension BrowserUsePiPModel: LivePreviewPiPModel {
  var changeKey: LivePreviewConnection.Status? { connection.status }

  var isMounted: Bool {
    !isDismissed && viewer != nil
  }

  var isVisible: Bool {
    isMounted && isLive
  }

  var title: String {
    if let title = connection.status?.title, !title.isEmpty { return title }
    if let url = connection.status?.url, let host = URL(string: url)?.host, !host.isEmpty { return host }
    return "Browser"
  }

  var tint: Color { .accentColor }
  var cursor: CGPoint? { nil }
  var cursorWindowWidth: CGFloat { 0 }
  var showsTarget: Bool { false }
  var canActivateTarget: Bool { false }
  var hasCustomSize: Bool { area != nil }

  var isLive: Bool {
    state == .active && connection.isConnected && viewer?.frameSize != nil
  }

  var statusText: String? { nil }

  var canReload: Bool { viewer != nil && state == .active }

  func appeared(isTurnRunning: Bool) {
    connection.start()
    sync()
  }

  func sync() {
    if state != .active, isDismissed {
      isDismissed = false
      Self.dismissedSessions.remove(chatSessionID)
    }
    switch state {
    case .active, .idle:
      guard !isDismissed, viewer == nil, state == .active else {
        viewer?.update(title: title)
        return
      }
      viewer = connection.makeViewer(title: title)
    case .stopped, .inactive:
      releaseViewer()
    }
  }

  func turnActivityChanged(isRunning: Bool) {}

  func teardown() {
    releaseViewer()
    connection.stop()
  }

  func dismiss() {
    isDismissed = true
    Self.dismissedSessions.insert(chatSessionID)
    releaseViewer()
  }

  func activateTarget() {}

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
