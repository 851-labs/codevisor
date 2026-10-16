import Foundation

public enum SyntaxTheme {
  public static func key(isDark: Bool) -> String {
    isDark ? "github-dark" : "github-light"
  }

  @MainActor
  public static func json(isDark: Bool) -> String? {
    let key = key(isDark: isDark)
    if let cached = cache[key] { return cached }
    cache[key] = .some(nil)
    guard
      let url = Bundle.module.url(forResource: key, withExtension: "json", subdirectory: "Themes"),
      let data = try? Data(contentsOf: url),
      let json = String(data: data, encoding: .utf8)
    else {
      assertionFailure("Bundled syntax theme \(key) is missing")
      return nil
    }
    cache[key] = json
    return json
  }

  @MainActor private static var cache: [String: String?] = [:]
}
