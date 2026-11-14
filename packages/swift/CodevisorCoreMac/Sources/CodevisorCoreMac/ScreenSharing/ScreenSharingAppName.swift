import Foundation
import SystemConfiguration

public enum ScreenSharingAppName {
  static let fallback = "Mac"
  static let maximumLength = 64

  public static var current: String {
    sanitised(SCDynamicStoreCopyComputerName(nil, nil) as String?)
  }

  static func sanitised(_ name: String?) -> String {
    let printable = (name ?? "").unicodeScalars.filter(isPrintable)
    let trimmed = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespacesAndNewlines)
    let shortened = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maximumLength)))
    return shortened.isEmpty ? fallback : shortened
  }

  private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory != .control && !lineSeparators.contains(scalar)
  }

  private static let lineSeparators: Set<Unicode.Scalar> = ["\u{2028}", "\u{2029}"]
}
