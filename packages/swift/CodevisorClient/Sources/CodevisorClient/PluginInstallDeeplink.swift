import Foundation

/// A parsed `codevisor://install-plugin?repo=owner/name` deeplink, as linked
/// from the web plugin directory (codevisor.dev/plugins). Deliberately
/// narrower than the install sheet's free-form source field: a link from the
/// outside world may only name a public GitHub repo — never a git URL or a
/// local path. The handler routes into the existing discover→consent→install
/// flow, so the user always sees the verbatim commands before anything runs.
public struct PluginInstallDeeplink: Equatable, Sendable {
  /// GitHub "owner/name" — handed to the install flow as the plugin source.
  public var repo: String

  public init(repo: String) {
    self.repo = repo
  }

  /// Universal links resolve their repository from registry metadata, never from URL input.
  public static func pluginID(from url: URL) -> String? {
    guard url.scheme?.lowercased() == "https",
      ["codevisor.dev", "www.codevisor.dev"].contains(url.host()?.lowercased() ?? ""),
      url.user == nil, url.password == nil, url.port == nil
    else { return nil }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2, parts[0] == "plugins" else { return nil }
    let id = String(parts[1])
    guard id.range(of: "^[a-z0-9-]+\\.[a-z0-9-]+$", options: .regularExpression) != nil else { return nil }
    return id
  }

  /// Accepts the whole Codevisor scheme family (production, dev, and
  /// per-instance dev schemes) so a build handles any link routed to it.
  public static func parse(_ url: URL) -> PluginInstallDeeplink? {
    guard CodevisorDeeplinkScheme.matches(url.scheme),
      url.host()?.lowercased() == "install-plugin",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let repo = components.queryItems?
        .first(where: { $0.name == "repo" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      isGitHubRepo(repo)
    else { return nil }
    return PluginInstallDeeplink(repo: repo)
  }

  /// The GitHub "owner/name" grammar: exactly two segments of ASCII
  /// letters, digits, `.`, `_`, and `-`, each starting alphanumeric.
  /// Anything else (URLs, paths, flags) is rejected outright.
  private static func isGitHubRepo(_ repo: String) -> Bool {
    let segments = repo.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count == 2 else { return false }
    return segments.allSatisfy { segment in
      guard let first = segment.unicodeScalars.first, isAlphanumeric(first) else {
        return false
      }
      return segment.unicodeScalars.allSatisfy { scalar in
        isAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
      }
    }
  }

  private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
      || ("0"..."9").contains(scalar)
  }
}
