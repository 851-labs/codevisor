import Foundation

public enum CodevisorDeeplinkScheme {
  public static var current: String {
    let schemes =
      (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
      .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] } ?? []
    let preferred = CodevisorAppVariant.isDevelopment ? "codevisor-dev" : "codevisor"
    if schemes.contains(preferred) { return preferred }
    return schemes.first { $0.hasPrefix("codevisor") } ?? preferred
  }

  public static func matches(_ scheme: String?) -> Bool {
    guard let scheme = scheme?.lowercased() else { return false }
    return scheme == "codevisor" || scheme == "codevisor-dev"
      || scheme.hasPrefix("codevisor-dev-")
  }
}
