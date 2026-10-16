import Foundation

public enum ColorMath {
  public static let minReadableRatio = 3.0

  public static func relativeLuminance(_ color: String?) -> Double? {
    guard let color, let rgba = RGBA(css: color) else { return nil }
    return rgba.relativeLuminance
  }

  public static func contrastRatio(_ a: Double, _ b: Double) -> Double {
    let hi = max(a, b)
    let lo = min(a, b)
    return (hi + 0.05) / (lo + 0.05)
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
}
