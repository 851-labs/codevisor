import CodevisorCoreMac
import CoreGraphics
import Foundation

@MainActor
enum PluginAppPiPPlacement {
  private static var cornerByChat: [UUID: ComputerUseLivePreviewCorner] = [:]
  private static var widthByChat: [UUID: CGFloat] = [:]

  static func corner(forChat chat: UUID) -> ComputerUseLivePreviewCorner {
    cornerByChat[chat] ?? .topTrailing
  }

  static func setCorner(_ corner: ComputerUseLivePreviewCorner, forChat chat: UUID) {
    cornerByChat[chat] = corner
  }

  static func width(forChat chat: UUID) -> CGFloat? {
    widthByChat[chat]
  }

  static func setWidth(_ width: CGFloat?, forChat chat: UUID) {
    widthByChat[chat] = width
  }
}
