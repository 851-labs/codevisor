import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import Observation
import SwiftUI
import TranscriptKit

@MainActor
@Observable
final class AgentLivePreviewPiPModel {
  nonisolated struct ChangeKey: Equatable, Sendable {
    let computer: ComputerUseLivePreview.Activity?
    let browser: LivePreviewConnection.Status?
    let lastUsedTool: LivePreviewConnection.Tool?
    let computerMounted: Bool
    let computerVisible: Bool
    let browserMounted: Bool
    let browserVisible: Bool
    let app: String?
  }

  private let computer: ComputerUsePiPModel?
  private let browser: BrowserUsePiPModel?
  private let chatSessionID: UUID
  private let apps: PluginAppDisplayRegistry
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var liveShownAt: Date?
  @ObservationIgnored private var wasLiveMounted = false

  init(
    chatSessionID: UUID, computer: ComputerUsePiPModel?, browser: BrowserUsePiPModel?,
    apps: PluginAppDisplayRegistry = .shared, now: @escaping () -> Date = Date.init
  ) {
    self.chatSessionID = chatSessionID
    self.computer = computer
    self.browser = browser
    self.apps = apps
    self.now = now
    if let computer, let browser {
      browser.corner = computer.corner
      browser.area = computer.area
    }
  }

  var appWidth: CGFloat? {
    get { PluginAppPiPPlacement.width(forChat: chatSessionID) }
    set { PluginAppPiPPlacement.setWidth(newValue, forChat: chatSessionID) }
  }

  private var shown: (any LivePreviewPiPModel)? {
    let mounted = byPreference.filter(\.isMounted)
    return mounted.first(where: \.isVisible) ?? mounted.first
  }

  private var byPreference: [any LivePreviewPiPModel] {
    let order: [(any LivePreviewPiPModel)?] =
      browser?.lastUsedTool == .browser ? [browser, computer] : [computer, browser]
    return order.compactMap { $0 }
  }

  private var placement: (any LivePreviewPiPModel)? {
    if let computer { return computer }
    return browser
  }

  private var children: [any LivePreviewPiPModel] {
    let all: [(any LivePreviewPiPModel)?] = [computer, browser]
    return all.compactMap { $0 }
  }

  private var isLiveMounted: Bool { children.contains(where: \.isMounted) }

  private func arbitrate() {
    let liveMounted = isLiveMounted
    if liveMounted, !wasLiveMounted { liveShownAt = now() }
    wasLiveMounted = liveMounted
    guard liveMounted, let app, let appStartedAt = apps.pipStartedAt else { return }
    guard let liveShownAt, liveShownAt > appStartedAt else {
      dismissLive()
      return
    }
    app.request(.inline)
  }

  private func dismissLive() {
    for child in children where child.isMounted { child.dismiss() }
    wasLiveMounted = false
  }
}

extension AgentLivePreviewPiPModel: LivePreviewPiPModel {
  var changeKey: ChangeKey {
    ChangeKey(
      computer: computer?.activity,
      browser: browser?.changeKey,
      lastUsedTool: browser?.lastUsedTool,
      computerMounted: computer?.isMounted == true,
      computerVisible: computer?.isVisible == true,
      browserMounted: browser?.isMounted == true,
      browserVisible: browser?.isVisible == true,
      app: app?.key)
  }

  var app: PluginAppInlineModel? { apps.pip(forChat: chatSessionID) }

  var isMounted: Bool { app != nil || shown != nil }
  var isVisible: Bool { app != nil || shown?.isVisible == true }
  var viewer: ComputerUseLivePreviewViewer? { app == nil ? shown?.viewer : nil }

  var corner: ComputerUseLivePreviewCorner {
    get { placement?.corner ?? PluginAppPiPPlacement.corner(forChat: chatSessionID) }
    set {
      computer?.corner = newValue
      browser?.corner = newValue
      PluginAppPiPPlacement.setCorner(newValue, forChat: chatSessionID)
    }
  }

  var area: CGFloat? {
    get { placement?.area }
    set {
      computer?.area = newValue
      browser?.area = newValue
    }
  }

  var title: String { app?.app.serverName ?? shown?.title ?? "" }
  var tint: Color { shown?.tint ?? .accentColor }
  var isLive: Bool { app != nil || shown?.isLive == true }
  var cursor: CGPoint? { app == nil ? shown?.cursor : nil }
  var cursorWindowWidth: CGFloat { shown?.cursorWindowWidth ?? 0 }
  var statusText: String? { app == nil ? shown?.statusText : nil }
  var showsTarget: Bool { app == nil && shown?.showsTarget == true }
  var canActivateTarget: Bool { app == nil && shown?.canActivateTarget == true }
  var canReload: Bool { app != nil || shown?.canReload == true }
  var hasCustomSize: Bool { app == nil ? area != nil : appWidth != nil }

  func appeared(isTurnRunning: Bool) {
    for child in children { child.appeared(isTurnRunning: isTurnRunning) }
    pauseHiddenBrowser()
    arbitrate()
  }

  func sync() {
    for child in children { child.sync() }
    pauseHiddenBrowser()
    arbitrate()
  }

  func turnActivityChanged(isRunning: Bool) {
    for child in children { child.turnActivityChanged(isRunning: isRunning) }
  }

  func teardown() {
    for child in children { child.teardown() }
  }

  func dismiss() {
    if let app {
      app.request(.inline)
      return
    }
    for child in children where child.isVisible { child.dismiss() }
  }

  func activateTarget() {
    guard app == nil else { return }
    shown?.activateTarget()
  }

  func reload() {
    if let app {
      app.retry()
      return
    }
    shown?.reload()
  }

  func resetSize() {
    if app != nil {
      appWidth = nil
      return
    }
    for child in children { child.resetSize() }
  }

  private func pauseHiddenBrowser() {
    guard let browser else { return }
    browser.setPaused(shown !== browser)
  }
}
