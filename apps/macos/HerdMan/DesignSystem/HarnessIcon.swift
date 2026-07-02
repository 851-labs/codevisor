import SwiftUI
import AppKit

/// The brand glyph for a harness (bundled lobe-icons SVG, template-tinted so it
/// follows the surrounding text color), falling back to an SF Symbol for
/// harnesses without a bundled icon.
struct HarnessIcon: View {
    let harnessId: String
    /// Shown when no bundled icon exists for the harness (e.g. the harness's
    /// registry symbol, or a neutral glyph for empty drafts).
    var fallbackSymbolName: String = "sparkle"
    var size: CGFloat = 13

    var body: some View {
        if let sized = Self.sizedImage(named: "harness-\(harnessId)", size: size) {
            Image(nsImage: sized)
                .renderingMode(.template)
        } else {
            Image(systemName: fallbackSymbolName)
                .font(.system(size: size - 1))
        }
    }

    /// Menus render images at their intrinsic size (ignoring SwiftUI frames),
    /// so the point size is baked into a copy of the catalog image instead.
    private static func sizedImage(named name: String, size: CGFloat) -> NSImage? {
        guard let image = NSImage(named: name), let copy = image.copy() as? NSImage else {
            return nil
        }
        copy.size = NSSize(width: size, height: size)
        copy.isTemplate = true
        return copy
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
