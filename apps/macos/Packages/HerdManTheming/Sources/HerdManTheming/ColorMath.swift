import Foundation

/// Canonical color/contrast primitives, ported from
/// `references/pierre/packages/theming/src/modules/color.ts`. All functions
/// take theme color strings (usually hex) and degrade gracefully on formats
/// they can't measure, matching the reference behavior.
public enum ColorMath {
    /// Primary-foreground floor (WCAG AA large text); used when picking the
    /// most legible foreground token for a surface.
    public static let minReadableRatio = 3.0
    /// Muted-text floor (WCAG AA normal text); used when deciding whether a
    /// description/muted token is readable on a surface.
    public static let minMutedRatio = 4.5

    /// WCAG relative luminance of a hex color in 0...1, or nil for non-hex
    /// inputs and nil. The alpha component of an 8-digit color is ignored.
    public static func relativeLuminance(_ color: String?) -> Double? {
        guard let color, let rgba = RGBA(css: color) else { return nil }
        return rgba.relativeLuminance
    }

    /// WCAG contrast ratio between two luminances; symmetric in its arguments.
    public static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b)
        let lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Composites a hex foreground over a hex background and returns the
    /// resulting opaque `#rrggbb`, or nil when either input is missing or
    /// unparseable.
    public static func compositeOverBg(_ fgColor: String, over bgColor: String?) -> String? {
        guard
            let bgColor,
            let fg = RGBA(css: fgColor),
            let bg = RGBA(css: bgColor)
        else { return nil }
        return fg.compositedOver(bg).hexString()
    }

    /// True when a color is fully transparent: the `transparent` keyword, a
    /// zero-alpha hex (`#rgb0` / `#rrggbb00`), or a functional color whose
    /// alpha component is effectively zero (`rgba(0,0,0,0)`, `rgb(0 0 0 / 0%)`).
    /// False for nil and any opaque color.
    public static func isFullyTransparent(_ color: String?) -> Bool {
        guard let color else { return false }
        let normalized = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "transparent" { return true }
        if normalized.hasPrefix("#") {
            let digits = String(normalized.dropFirst())
            guard digits.allSatisfy(\.isHexDigit) else { return false }
            if digits.count == 4 { return digits.hasSuffix("0") }
            if digits.count == 8 { return digits.hasSuffix("00") }
            return false
        }
        guard let alpha = functionalAlpha(of: normalized) else { return false }
        return alphaIsZero(alpha)
    }

    /// True when a chrome surface is perceptually dark. Prefers the surface's
    /// own luminance (dark when < 0.4); when the bg isn't parseable, falls back
    /// to a foreground hint (light fg → dark surface). A missing hint → false.
    public static func isDarkSurface(bg: String?, fgHint: String? = nil) -> Bool {
        if let fromBg = relativeLuminance(bg) { return fromBg < 0.4 }
        if let fromFg = relativeLuminance(fgHint) { return fromFg > 0.6 }
        return false
    }

    /// True when two colors read as the "same surface": identical string
    /// (case- and whitespace-insensitive) or close enough in luminance
    /// (Δ < 0.06). Unmeasurable or nil inputs are treated as non-matching.
    public static func surfacesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        if a.trimmingCharacters(in: .whitespaces).lowercased()
            == b.trimmingCharacters(in: .whitespaces).lowercased() {
            return true
        }
        guard let la = relativeLuminance(a), let lb = relativeLuminance(b) else { return false }
        return abs(la - lb) < 0.06
    }

    /// True when `hover` is closer in luminance to `fg` than to `bg` — i.e.
    /// the hover surface would land on top of the row text rather than next to
    /// it, erasing legibility. False when anything is missing or unparseable
    /// (unknown format → trust the theme designer's intent).
    public static func hoverWouldEraseText(hover: String, bg: String?, fg: String?) -> Bool {
        guard
            let bg, let fg,
            let hoverL = relativeLuminance(hover),
            let bgL = relativeLuminance(bg),
            let fgL = relativeLuminance(fg)
        else { return false }
        return abs(hoverL - fgL) < abs(hoverL - bgL)
    }

    /// Walks `candidates` in priority order. Returns the first color whose
    /// contrast against `bg` clears `minReadableRatio`; if nothing reaches the
    /// bar, returns the candidate with the highest contrast, so weakly-typed
    /// themes land on the brightest available token. Unmeasurable candidates
    /// are only returned via the first-defined fallback when nothing parses.
    public static func pickReadableForeground(
        bg: String?,
        candidates: [String?]
    ) -> String? {
        let firstDefined = candidates.compactMap { $0 }.first { !$0.isEmpty }
        guard let bgL = relativeLuminance(bg) else { return firstDefined }
        var best: String?
        var bestRatio = -1.0
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            guard let candidateL = relativeLuminance(candidate) else { continue }
            let ratio = contrastRatio(bgL, candidateL)
            if ratio >= minReadableRatio { return candidate }
            if ratio > bestRatio {
                best = candidate
                bestRatio = ratio
            }
        }
        return best ?? firstDefined
    }

    /// Mixes `primaryFg` toward `bg` until the result clears `minMutedRatio`,
    /// stepping from a strong-hierarchy 60% blend up to 90%. Falls back to
    /// `primaryFg` when nothing clears the bar or an input isn't parseable —
    /// dim but legible chrome beats stylish but unreadable chrome.
    public static func deriveMutedFg(primaryFg: String, bg: String?) -> String {
        guard
            let bg,
            let fg = RGBA(css: primaryFg),
            let bgColor = RGBA(css: bg)
        else { return primaryFg }
        let bgL = bgColor.relativeLuminance
        for weight in [0.6, 0.7, 0.8, 0.9] {
            let mixed = fg.mixed(with: bgColor, weight: weight)
            if contrastRatio(bgL, mixed.relativeLuminance) >= minMutedRatio {
                return mixed.hexString()
            }
        }
        return primaryFg
    }

    // Extracts the alpha component from a functional color notation
    // (rgb/rgba/hsl/hsla/hwb/lab/lch/oklab/oklch/color), supporting both the
    // modern slash syntax (`rgb(0 0 0 / 0)`) and the legacy comma syntax
    // (`rgba(0, 0, 0, 0)`). Returns nil when the input isn't a recognized
    // functional notation or has no alpha component.
    private static func functionalAlpha(of color: String) -> String? {
        guard
            let openParen = color.firstIndex(of: "("),
            openParen != color.startIndex,
            color.hasSuffix(")")
        else { return nil }

        let fn = color[..<openParen].trimmingCharacters(in: .whitespaces)
        let knownFunctions: Set<String> = [
            "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color",
        ]
        guard knownFunctions.contains(fn) else { return nil }

        let innerStart = color.index(after: openParen)
        let innerEnd = color.index(before: color.endIndex)
        let inner = color[innerStart..<innerEnd].trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }

        if let slashIndex = inner.lastIndex(of: "/") {
            return String(inner[inner.index(after: slashIndex)...])
                .trimmingCharacters(in: .whitespaces)
        }

        if fn == "rgba" || fn == "hsla" {
            let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count == 4 {
                return parts[3].trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    // Matches an alpha component that is effectively zero: `0`, `0.0`, `0%`.
    private static func alphaIsZero(_ alpha: String) -> Bool {
        var value = alpha
        if value.hasSuffix("%") { value.removeLast() }
        guard let parsed = Double(value) else { return false }
        return parsed == 0
    }
}
