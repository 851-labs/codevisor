import CoreGraphics
import Testing

@testable import CodevisorUI

@Suite("Plugin app picture in picture layout")
struct PluginAppPipLayoutTests {
  private let container = CGSize(width: 800, height: 600)

  @Test("A dropped window settles in the corner nearest its center")
  func snapping() {
    #expect(PluginAppPipLayout.nearestCorner(to: CGPoint(x: 100, y: 100), container: container) == .topLeading)
    #expect(PluginAppPipLayout.nearestCorner(to: CGPoint(x: 700, y: 120), container: container) == .topTrailing)
    #expect(PluginAppPipLayout.nearestCorner(to: CGPoint(x: 90, y: 500), container: container) == .bottomLeading)
    #expect(PluginAppPipLayout.nearestCorner(to: CGPoint(x: 650, y: 590), container: container) == .bottomTrailing)
  }

  @Test("The window follows the app's height within bounds and stays inside a narrow chat")
  func sizing() {
    let tall = PluginAppPipLayout.size(contentHeight: 2_000, container: container, preferredWidth: 360)
    #expect(tall == CGSize(width: 360, height: 360 + PluginAppPipLayout.headerHeight))
    #expect(
      PluginAppPipLayout.origin(corner: .bottomTrailing, size: tall, container: container)
        == CGPoint(x: 800 - 360 - 12, y: 600 - tall.height - 12))

    let narrow = CGSize(width: 300, height: 900)
    let fitted = PluginAppPipLayout.size(contentHeight: 50, container: narrow, preferredWidth: 360)
    #expect(fitted == CGSize(width: 276, height: 120 + PluginAppPipLayout.headerHeight))
    #expect(
      PluginAppPipLayout.origin(corner: .bottomTrailing, size: fitted, container: narrow)
        == CGPoint(x: 12, y: 900 - fitted.height - 12))
  }
}
