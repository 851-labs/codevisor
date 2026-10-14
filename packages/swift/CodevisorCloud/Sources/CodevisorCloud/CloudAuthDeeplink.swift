import CodevisorClient
import Foundation

public struct CloudAuthDeeplink: Equatable, Sendable {
  public var ott: String

  public init(ott: String) {
    self.ott = ott
  }

  public static func parse(_ url: URL) -> CloudAuthDeeplink? {
    guard CodevisorDeeplinkScheme.matches(url.scheme),
      url.host()?.lowercased() == "cloud-auth",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let ott = components.queryItems?
        .first(where: { $0.name == "ott" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !ott.isEmpty
    else { return nil }
    return CloudAuthDeeplink(ott: ott)
  }
}
