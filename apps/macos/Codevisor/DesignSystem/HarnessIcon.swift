import SwiftUI
import AppKit
import CodevisorUI

struct HarnessIcon: View {
  let harnessId: String
  var fallbackSymbolName: String = "sparkle"
  var size: CGFloat = 13
  var weight: NSFont.Weight = .regular

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let _ = colorScheme
    if let symbol = Self.rasterizedSymbol(harnessId: harnessId, size: size, weight: weight) {
      Image(nsImage: symbol)
        .renderingMode(.template)
    } else {
      MenuSymbolIcon(systemName: fallbackSymbolName, size: size, weight: weight)
    }
  }

  private static func rasterizedSymbol(harnessId: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
    MenuSymbolIcon.rasterized(cacheKey: "harness:\(harnessId)@\(size)/\(weight.rawValue)", size: size, weight: weight) {
      CodevisorSymbol.harnessImage(harnessId)
    }
  }
}

struct MenuSymbolIcon: View {
  let systemName: String
  var size: CGFloat = 13
  var weight: NSFont.Weight = .regular

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let _ = colorScheme
    if let symbol = Self.rasterizedSymbol(named: systemName, size: size, weight: weight) {
      Image(nsImage: symbol)
        .renderingMode(.template)
    } else {
      Image(systemName: systemName)
        .font(.system(size: size))
    }
  }

  static func rasterizedSymbol(named name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
    rasterized(cacheKey: "symbol:\(name)@\(size)/\(weight.rawValue)", size: size, weight: weight) {
      NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
  }

  static func rasterized(cacheKey: String, size: CGFloat, weight: NSFont.Weight, symbol: () -> NSImage?) -> NSImage? {
    MenuIconRasterizer.tinted(cacheKey: cacheKey) {
      guard
        let configured = symbol()?.withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        )
      else { return nil }
      return MenuIconRasterizer.labelTintedBitmap(drawing: configured, size: configured.size)
    }
  }
}

@MainActor
enum MenuIconRasterizer {
  private static var cache: [String: NSImage] = [:]
  private static var cachedAppearance: String?

  static func tinted(cacheKey: String, make: () -> NSImage?) -> NSImage? {
    let appearance = NSApp.effectiveAppearance.name.rawValue
    if cachedAppearance != appearance {
      cache.removeAll(keepingCapacity: true)
      cachedAppearance = appearance
    }
    if let cached = cache[cacheKey] { return cached }
    guard let made = make() else { return nil }
    cache[cacheKey] = made
    return made
  }

  static func labelTintedBitmap(drawing image: NSImage, size: NSSize) -> NSImage? {
    let scale: CGFloat = 2
    guard size.width > 0, size.height > 0,
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
      let rect = NSRect(origin: .zero, size: size)
      image.draw(in: rect)
      NSColor.labelColor.set()
      rect.fill(using: .sourceAtop)
    }
    NSGraphicsContext.restoreGraphicsState()
    let drawn = NSImage(size: size)
    drawn.addRepresentation(rep)
    drawn.isTemplate = true
    return drawn
  }
}
