#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete search layout")
  @MainActor
  struct InputLayoutTests {
    @Test("Font changes resize native symbols and preserve nonoverlapping search keylines in both directions")
    func fontAndDirectionChanges() throws {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
        styleMask: [.borderless], backing: .buffered, defer: false)
      let container = Autocomplete.InputCapsuleView(metrics: .xcodeMenu, showsCheckmarks: false, showsIcons: false)
      window.contentView = container
      defer { window.contentView = nil }
      let icon = try #require(container.subviews.compactMap { $0 as? NSImageView }.first)
      let field = container.searchField
      for fontSize in [13.0, 24, 36, 18, 13] {
        var metrics = Autocomplete.Metrics()
        metrics.fontSize = fontSize
        metrics = metrics.resolved()
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
          for checks in [false, true] {
            for icons in [false, true] {
              container.userInterfaceLayoutDirection = direction
              container.configure(metrics: metrics, showsCheckmarks: checks, showsIcons: icons)
              container.layoutSubtreeIfNeeded()
              #expect(container.bounds.contains(field.frame))
              #expect(container.bounds.contains(icon.frame))
              #expect(!field.frame.intersects(icon.frame))
              #expect(icon.image?.size.width ?? 0 > fontSize * 0.8)
              #expect(icon.image?.size.width ?? .infinity < fontSize * 1.5)
              if direction == .rightToLeft {
                #expect(icon.frame.minX > field.frame.maxX)
              } else {
                #expect(icon.frame.maxX < field.frame.minX)
              }
            }
          }
        }
      }
    }

    @Test("Resolved metrics scale glyph slots once and retain explicit minimum dimensions")
    func resolvedMetrics() {
      var metrics = Autocomplete.Metrics()
      metrics.fontSize = 32
      metrics.itemHeight = 80
      metrics.itemAccessoryWidth = 72
      let resolved = metrics.resolved()
      #expect(resolved == resolved.resolved())
      #expect(resolved.itemHeight == 80)
      #expect(resolved.itemAccessoryWidth == 72)
      #expect(resolved.itemIconSize >= 32)
      #expect(resolved.checkColumnWidth > resolved.checkmarkFontSize)
      #expect(resolved.itemAccessoryWidth > resolved.accessoryFontSize)
      #expect(resolved.inputHeight > resolved.itemHeight)
      #expect(resolved.bottomCornerRadius == metrics.bottomCornerRadius)
    }
  }
#endif
