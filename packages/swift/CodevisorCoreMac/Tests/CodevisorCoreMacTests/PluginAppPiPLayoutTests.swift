import CoreGraphics
import Testing

@testable import CodevisorCoreMac

@Suite("Plugin app picture in picture layout")
struct PluginAppPiPLayoutTests {
  private let insets = ComputerUseLivePreviewInsets(top: 12, leading: 12, bottom: 100, trailing: 12)
  private let window = CGSize(width: 1_200, height: 800)

  @Test("An app card starts at the default width and is as tall as the app's content")
  func defaults() {
    let size = PluginAppPiPLayout.size(width: nil, contentHeight: 312.4, container: window, insets: insets)

    #expect(size == CGSize(width: 360, height: 312))
  }

  @Test("Width stays between the minimum and the live preview's share of the window; height fits the window")
  func limits() {
    let narrow = PluginAppPiPLayout.size(width: 100, contentHeight: 20, container: window, insets: insets)
    let wide = PluginAppPiPLayout.size(width: 5_000, contentHeight: 5_000, container: window, insets: insets)

    #expect(narrow == CGSize(width: 240, height: 80))
    #expect(wide == CGSize(width: 706, height: 688))
  }

  @Test("Dragging an edge changes only the width, mirrored for the leading edge, never below the minimum")
  func resize() {
    #expect(PluginAppPiPLayout.resizedWidth(handle: .trailing, startWidth: 360, translation: 40) == 400)
    #expect(PluginAppPiPLayout.resizedWidth(handle: .bottomLeading, startWidth: 360, translation: 40) == 320)
    #expect(PluginAppPiPLayout.resizedWidth(handle: .leading, startWidth: 300, translation: 200) == 240)
  }
}
