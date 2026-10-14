import Foundation

public enum CodevisorDeeplinkScheme {
  public static func matches(_ scheme: String?) -> Bool {
    guard let scheme = scheme?.lowercased() else { return false }
    return scheme == "codevisor" || scheme == "codevisor-dev"
      || scheme.hasPrefix("codevisor-dev-")
  }
}
