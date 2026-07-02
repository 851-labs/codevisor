import Foundation

/// An sRGB color with channels in 0...255 and alpha in 0...1, mirroring the
/// representation used by the reference TypeScript implementation
/// (`references/pierre/packages/theming/src/modules/color.ts`) so the ported
/// math stays comparable value-for-value.
public struct RGBA: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parses `#rgb`, `#rgba`, `#rrggbb`, or `#rrggbbaa` (case-insensitive,
    /// surrounding whitespace tolerated). Returns nil for any other format.
    public init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = String(trimmed.dropFirst())
        guard digits.allSatisfy(\.isHexDigit) else { return nil }

        let expanded: String
        switch digits.count {
        case 3, 4:
            expanded = digits.map { "\($0)\($0)" }.joined()
        case 6, 8:
            expanded = digits
        default:
            return nil
        }

        func byte(_ offset: Int) -> Double? {
            let start = expanded.index(expanded.startIndex, offsetBy: offset)
            let end = expanded.index(start, offsetBy: 2)
            return UInt8(expanded[start..<end], radix: 16).map(Double.init)
        }

        guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
        var a = 1.0
        if expanded.count == 8 {
            guard let alphaByte = byte(6) else { return nil }
            a = alphaByte / 255
        }
        self.init(r: r, g: g, b: b, a: a)
    }

    /// Parses any color notation themes actually use: hex (all four widths)
    /// or `color(display-p3 r g b [/ a])` — the notation pierre's generated
    /// themes emit. P3 components are converted to sRGB (gamut-clamped).
    /// Returns nil for anything else.
    public init?(css: String) {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            self.init(hex: trimmed)
            return
        }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("color("), lower.hasSuffix(")") else { return nil }
        let inner = lower.dropFirst("color(".count).dropLast()

        // Split off the optional `/ alpha` component.
        let slashParts = inner.split(separator: "/", maxSplits: 1)
        var alpha = 1.0
        if slashParts.count == 2 {
            guard let parsed = Double(slashParts[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            alpha = max(0, min(1, parsed))
        }

        let components = slashParts[0].split(separator: " ").map(String.init)
        guard components.count == 4, components[0] == "display-p3",
            let p3r = Double(components[1]),
            let p3g = Double(components[2]),
            let p3b = Double(components[3])
        else { return nil }

        let srgb = Self.displayP3ToSRGB(r: p3r, g: p3g, b: p3b)
        self.init(r: srgb.r * 255, g: srgb.g * 255, b: srgb.b * 255, a: alpha)
    }

    // Converts gamma-encoded Display-P3 components (0...1) to gamma-encoded
    // sRGB via linear P3 → XYZ (D65) → linear sRGB, clamping out-of-gamut
    // values to the sRGB cube.
    private static func displayP3ToSRGB(
        r: Double, g: Double, b: Double
    ) -> (r: Double, g: Double, b: Double) {
        // Display-P3 uses the sRGB transfer curve.
        func decode(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func encode(_ v: Double) -> Double {
            let clamped = max(0, min(1, v))
            return clamped <= 0.0031308
                ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        let lr = decode(r)
        let lg = decode(g)
        let lb = decode(b)
        // Linear P3 → XYZ (D65)
        let x = 0.48657095 * lr + 0.26566769 * lg + 0.19821729 * lb
        let y = 0.22897456 * lr + 0.69173852 * lg + 0.07928691 * lb
        let z = 0.00000000 * lr + 0.04511338 * lg + 1.04394437 * lb
        // XYZ → linear sRGB
        let sr = 3.24096994 * x - 1.53738318 * y - 0.49861076 * z
        let sg = -0.96924364 * x + 1.87596750 * y + 0.04155506 * z
        let sb = 0.05563008 * x - 0.20397696 * y + 1.05697151 * z
        return (encode(sr), encode(sg), encode(sb))
    }

    /// Lowercase `#rrggbb`, or `#rrggbbaa` when `includeAlpha` is true.
    public func hexString(includeAlpha: Bool = false) -> String {
        func hex(_ value: Double) -> String {
            let clamped = max(0, min(255, Int(value.rounded())))
            return String(format: "%02x", clamped)
        }
        var result = "#" + hex(r) + hex(g) + hex(b)
        if includeAlpha {
            result += hex(a * 255)
        }
        return result
    }

    /// Linear sRGB mix, the native replacement for CSS
    /// `color-mix(in srgb, self weight%, other)`. `weight` is the fraction of
    /// self in the result (0...1); alpha mixes the same way.
    public func mixed(with other: RGBA, weight: Double) -> RGBA {
        let w = max(0, min(1, weight))
        return RGBA(
            r: (r * w + other.r * (1 - w)).rounded(),
            g: (g * w + other.g * (1 - w)).rounded(),
            b: (b * w + other.b * (1 - w)).rounded(),
            a: a * w + other.a * (1 - w)
        )
    }

    /// Standard alpha compositing of self over an (assumed opaque) background;
    /// the result is opaque. Used to measure the real contrast of
    /// semi-transparent tokens against the surface they render on.
    public func compositedOver(_ background: RGBA) -> RGBA {
        RGBA(
            r: (r * a + background.r * (1 - a)).rounded(),
            g: (g * a + background.g * (1 - a)).rounded(),
            b: (b * a + background.b * (1 - a)).rounded(),
            a: 1
        )
    }

    /// WCAG relative luminance in 0...1. Alpha is ignored — composite first
    /// when measuring a transparent color against a surface.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            let v = value / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Returns a copy with the given alpha.
    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(r: r, g: g, b: b, a: alpha)
    }
}
