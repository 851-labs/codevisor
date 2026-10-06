//  What the picture-in-picture card needs from its model, so one card shows
//  either the app an agent controls through Computer Use or the tab it drives
//  through Browser Use.

import CodevisorCoreMac
import Observation
import SwiftUI

@MainActor
protocol LivePreviewPiPModel: AnyObject, Observable {
  associatedtype ChangeKey: Equatable

  /// Changes whenever the card should reconcile its viewer (`sync()`).
  var changeKey: ChangeKey { get }
  var isVisible: Bool { get }
  var viewer: ComputerUseLivePreviewViewer? { get }
  var corner: ComputerUseLivePreviewCorner { get set }
  /// The preferred card area in square points; nil for the default fit.
  var area: CGFloat? { get set }
  var title: String { get }
  var tint: Color { get }
  var isLive: Bool { get }
  /// The agent cursor as a 0…1 fraction of the frame, when drawn by the card.
  var cursor: CGPoint? { get }
  /// The width of the window the cursor moves in, to scale it with the card.
  var cursorWindowWidth: CGFloat { get }
  var statusText: String? { get }
  /// Whether the menu offers to bring the previewed target forward.
  var showsTarget: Bool { get }
  var canActivateTarget: Bool { get }
  var canReload: Bool { get }
  var hasCustomSize: Bool { get }

  func appeared(isTurnRunning: Bool)
  func sync()
  func turnActivityChanged(isRunning: Bool)
  func teardown()
  func dismiss()
  func activateTarget()
  func reload()
  func resetSize()
}

extension ComputerUsePiPModel: LivePreviewPiPModel {
  var changeKey: ComputerUseLivePreview.Activity? { activity }
  var showsTarget: Bool { !isRemote }
  var cursorWindowWidth: CGFloat { activity?.windowFrame.width ?? 0 }
}
