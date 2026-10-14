import Foundation

public enum ColorMath {
  public static let minReadableRatio = 3.0
  public static let minMutedRatio = 4.5

  public static func relativeLuminance(_ color: String?) -> Double? {
    guard let color, let rgba = RGBA(css: color) else { return nil }
    return rgba.relativeLuminance
  }

  public static func contrastRatio(_ a: Double, _ b: Double) -> Double {
    let hi = max(a, b)
    let lo = min(a, b)
    return (hi + 0.05) / (lo + 0.05)
  }

  public static func compositeOverBg(_ fgColor: String, over bgColor: String?) -> String? {
    guard
      let bgColor,
      let fg = RGBA(css: fgColor),
      let bg = RGBA(css: bgColor)
    else { return nil }
    return fg.compositedOver(bg).hexString()
  }

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

  public static func isDarkSurface(bg: String?, fgHint: String? = nil) -> Bool {
    if let fromBg = relativeLuminance(bg) { return fromBg < 0.4 }
    if let fromFg = relativeLuminance(fgHint) { return fromFg > 0.6 }
    return false
  }

  public static func surfacesMatch(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    if a.trimmingCharacters(in: .whitespaces).lowercased()
      == b.trimmingCharacters(in: .whitespaces).lowercased()
    {
      return true
    }
    guard let la = relativeLuminance(a), let lb = relativeLuminance(b) else { return false }
    return abs(la - lb) < 0.06
  }

  public static func hoverWouldEraseText(hover: String, bg: String?, fg: String?) -> Bool {
    guard
      let bg, let fg,
      let hoverL = relativeLuminance(hover),
      let bgL = relativeLuminance(bg),
      let fgL = relativeLuminance(fg)
    else { return false }
    return abs(hoverL - fgL) < abs(hoverL - bgL)
  }

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

  private static func alphaIsZero(_ alpha: String) -> Bool {
    var value = alpha
    if value.hasSuffix("%") { value.removeLast() }
    guard let parsed = Double(value) else { return false }
    return parsed == 0
  }
}
