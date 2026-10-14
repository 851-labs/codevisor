import CodevisorCore
import CodevisorCoreMac
import Observation
import SwiftUI

@MainActor
@Observable
final class AgentLivePreviewPiPModel {
  nonisolated struct ChangeKey: Equatable, Sendable {
    let computer: ComputerUseLivePreview.Activity?
    let browser: LivePreviewConnection.Status?
    let lastUsedTool: LivePreviewConnection.Tool?
    let computerVisible: Bool
    let browserVisible: Bool
  }

  private let computer: ComputerUsePiPModel?
  private let browser: BrowserUsePiPModel?

  init(computer: ComputerUsePiPModel?, browser: BrowserUsePiPModel?) {
    self.computer = computer
    self.browser = browser
    if let computer, let browser {
      browser.corner = computer.corner
      browser.area = computer.area
    }
  }

  private var shown: (any LivePreviewPiPModel)? {
    let showsComputer = computer?.isVisible == true
    if browser?.isVisible == true, !showsComputer || browser?.lastUsedTool == .browser { return browser }
    return showsComputer ? computer : nil
  }

  private var placement: (any LivePreviewPiPModel)? {
    if let computer { return computer }
    return browser
  }

  private var children: [any LivePreviewPiPModel] {
    let all: [(any LivePreviewPiPModel)?] = [computer, browser]
    return all.compactMap { $0 }
  }
}

extension AgentLivePreviewPiPModel: LivePreviewPiPModel {
  var changeKey: ChangeKey {
    ChangeKey(
      computer: computer?.activity,
      browser: browser?.changeKey,
      lastUsedTool: browser?.lastUsedTool,
      computerVisible: computer?.isVisible == true,
      browserVisible: browser?.isVisible == true)
  }

  var isVisible: Bool { shown != nil }
  var viewer: ComputerUseLivePreviewViewer? { shown?.viewer }

  var corner: ComputerUseLivePreviewCorner {
    get { placement?.corner ?? .topTrailing }
    set {
      computer?.corner = newValue
      browser?.corner = newValue
    }
  }

  var area: CGFloat? {
    get { placement?.area }
    set {
      computer?.area = newValue
      browser?.area = newValue
    }
  }

  var title: String { shown?.title ?? "" }
  var tint: Color { shown?.tint ?? .accentColor }
  var isLive: Bool { shown?.isLive ?? false }
  var cursor: CGPoint? { shown?.cursor }
  var cursorWindowWidth: CGFloat { shown?.cursorWindowWidth ?? 0 }
  var statusText: String? { shown?.statusText }
  var showsTarget: Bool { shown?.showsTarget ?? false }
  var canActivateTarget: Bool { shown?.canActivateTarget ?? false }
  var canReload: Bool { shown?.canReload ?? false }
  var hasCustomSize: Bool { area != nil }

  func appeared(isTurnRunning: Bool) {
    for child in children { child.appeared(isTurnRunning: isTurnRunning) }
    pauseHiddenBrowser()
  }

  func sync() {
    for child in children { child.sync() }
    pauseHiddenBrowser()
  }

  func turnActivityChanged(isRunning: Bool) {
    for child in children { child.turnActivityChanged(isRunning: isRunning) }
  }

  func teardown() {
    for child in children { child.teardown() }
  }

  func dismiss() {
    for child in children where child.isVisible { child.dismiss() }
  }

  func activateTarget() { shown?.activateTarget() }
  func reload() { shown?.reload() }

  func resetSize() {
    for child in children { child.resetSize() }
  }

  private func pauseHiddenBrowser() {
    guard let browser else { return }
    browser.setPaused(shown !== browser)
  }
}
