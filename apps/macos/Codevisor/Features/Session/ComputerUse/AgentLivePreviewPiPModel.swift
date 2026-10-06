//  The one picture-in-picture card over a chat. It shows whichever of the
//  agent's tools it touched last, Computer Use or Browser Use, among those
//  with something to show, and switches as the agent moves between them.

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

  /// Nil where the chat's machine can't show that tool.
  private let computer: ComputerUsePiPModel?
  private let browser: BrowserUsePiPModel?

  init(computer: ComputerUsePiPModel?, browser: BrowserUsePiPModel?) {
    self.computer = computer
    self.browser = browser
    // One card, one place: both views share the corner and size.
    if let computer, let browser {
      browser.corner = computer.corner
      browser.area = computer.area
    }
  }

  /// The view on the card: the tool touched last when both have something
  /// to show, otherwise whichever does.
  private var shown: (any LivePreviewPiPModel)? {
    let showsComputer = computer?.isVisible == true
    if browser?.isVisible == true, !showsComputer || browser?.lastUsedTool == .browser { return browser }
    return showsComputer ? computer : nil
  }

  /// Where the card's placement is kept.
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

  /// Closing the card closes every view it could switch to, so it doesn't
  /// reappear with the other tool. Each returns once its tool's activity
  /// ends and starts again.
  func dismiss() {
    for child in children where child.isVisible { child.dismiss() }
  }

  func activateTarget() { shown?.activateTarget() }
  func reload() { shown?.reload() }

  func resetSize() {
    for child in children { child.resetSize() }
  }

  /// The tab's frames stream only while the card shows it.
  private func pauseHiddenBrowser() {
    guard let browser else { return }
    browser.setPaused(shown !== browser)
  }
}
