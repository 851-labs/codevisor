import SwiftUI
import AppKit

/// The brand glyph for a harness (bundled lobe-icons SVG, tinted to the label
/// color so it follows the surrounding text), falling back to an SF Symbol for
/// harnesses without a bundled icon.
struct HarnessIcon: View {
    let harnessId: String
    /// Shown when no bundled icon exists for the harness (e.g. the harness's
    /// registry symbol, or a neutral glyph for empty drafts).
    var fallbackSymbolName: String = "sparkle"
    var size: CGFloat = 13

    // Re-rasterize when the appearance flips so the baked-in label color
    // tracks light/dark mode (see MenuIconRasterizer).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = colorScheme
        if let sized = Self.sizedImage(named: "harness-\(harnessId)", size: size) {
            Image(nsImage: sized)
                .renderingMode(.template)
        } else {
            MenuSymbolIcon(systemName: fallbackSymbolName, size: size)
        }
    }

    /// Menus render images at their intrinsic size (ignoring SwiftUI frames)
    /// and never tint them, so the point size and label color are both baked
    /// into a bitmap copy of the catalog image.
    private static func sizedImage(named name: String, size: CGFloat) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        return MenuIconRasterizer.labelTintedBitmap(
            drawing: image,
            size: NSSize(width: size, height: size)
        )
    }
}

/// An SF Symbol that reliably shows up in menu items. Menu labels drop
/// symbol-backed images entirely — `Image(systemName:)` and
/// `NSImage(systemSymbolName:)` alike — so the symbol is rasterized into a
/// label-tinted bitmap (see MenuIconRasterizer).
struct MenuSymbolIcon: View {
    let systemName: String
    var size: CGFloat = 13

    // Re-rasterize when the appearance flips so the baked-in label color
    // tracks light/dark mode.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = colorScheme
        if let symbol = Self.rasterizedSymbol(named: systemName, size: size) {
            Image(nsImage: symbol)
                .renderingMode(.template)
        } else {
            Image(systemName: systemName)
                .font(.system(size: size - 1))
        }
    }

    static func rasterizedSymbol(named name: String, size: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = symbol.withSymbolConfiguration(
                  NSImage.SymbolConfiguration(pointSize: size - 1, weight: .medium)
              )
        else { return nil }
        return MenuIconRasterizer.labelTintedBitmap(drawing: configured, size: configured.size)
    }
}

/// Menus draw images literally: they ignore both symbol backing and the
/// template flag on programmatic images, so neither SF Symbols nor
/// template-tinting survive the bridge. The workaround shared by the composer
/// pickers is to rasterize the glyph into a real bitmap with the label color
/// (resolved for the app's current appearance — white in dark mode, black in
/// light) baked into the pixels. The result still carries `isTemplate`, so
/// regular SwiftUI views retint it with the surrounding foreground style as
/// usual; the baked color only shows where menus draw it literally.
@MainActor
enum MenuIconRasterizer {
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
            // Recolor the glyph in place: sourceAtop keeps the alpha mask and
            // replaces the artwork's own color with the label color.
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

/// Prefers the filled variant of an SF Symbol when one exists — the sidebar
/// uses filled icons only, but older projects may have unfilled symbols saved.
@MainActor
enum FilledSymbol {
    private static var cache: [String: String] = [:]

    static func preferred(_ symbol: String) -> String {
        if let cached = cache[symbol] { return cached }
        let filled = symbol + ".fill"
        let resolved: String
        if symbol.contains(".fill") {
            resolved = symbol
        } else if NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil {
            resolved = filled
        } else {
            resolved = symbol
        }
        cache[symbol] = resolved
        return resolved
    }
}
