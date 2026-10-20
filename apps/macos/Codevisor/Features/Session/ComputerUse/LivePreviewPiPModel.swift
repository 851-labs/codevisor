import CodevisorCoreMac
import Observation
import SwiftUI

@MainActor
protocol LivePreviewPiPModel: AnyObject, Observable {
  associatedtype ChangeKey: Equatable

  var changeKey: ChangeKey { get }
  var isMounted: Bool { get }
  var isVisible: Bool { get }
  var viewer: ComputerUseLivePreviewViewer? { get }
  var corner: ComputerUseLivePreviewCorner { get set }
  var area: CGFloat? { get set }
  var title: String { get }
  var tint: Color { get }
  var isLive: Bool { get }
  var cursor: CGPoint? { get }
  var cursorWindowWidth: CGFloat { get }
  var statusText: String? { get }
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
