import Foundation

/// The URL schemes a Codevisor build may register: `codevisor` (production),
/// `codevisor-dev` (plain development builds), and `codevisor-dev-<instance>`
/// (per-worktree dev instances — `bun run dev` suffixes the scheme with the
/// worktree's instance hash so parallel dev apps never race for one handler,
/// mirroring how it suffixes the bundle identifier).
public enum CodevisorDeeplinkScheme {
  /// True when `scheme` belongs to some Codevisor build. Every deeplink
  /// parser accepts the whole family, so a link generated for one variant
  /// still parses in whichever variant the OS actually routed it to.
  public static func matches(_ scheme: String?) -> Bool {
    guard let scheme = scheme?.lowercased() else { return false }
    return scheme == "codevisor" || scheme == "codevisor-dev"
      || scheme.hasPrefix("codevisor-dev-")
  }
}
