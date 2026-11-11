import Foundation

public struct ChromeProfiles: Sendable, Equatable {
  public static let empty = ChromeProfiles(profiles: [], lastUsed: nil)

  public let profiles: [ChromeProfile]
  public let lastUsed: ChromeProfile.ID?

  public var preferred: ChromeProfile? {
    profiles.first { $0.id == lastUsed } ?? profiles.first
  }

  @concurrent
  public static func load(
    from root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Google/Chrome")
  ) async -> ChromeProfiles {
    guard let state = ChromeLocalState(root: root) else { return .empty }

    let profiles = state.profiles.filter { FileManager.default.fileExists(atPath: $0.cookies.path) }
    return ChromeProfiles(profiles: profiles, lastUsed: state.lastUsed)
  }
}

private struct ChromeLocalState {
  let profiles: [ChromeProfile]
  let lastUsed: String?

  init?(root: URL) {
    guard let data = try? Data(contentsOf: root.appending(path: "Local State")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profile = json["profile"] as? [String: Any],
      let cache = profile["info_cache"] as? [String: [String: Any]]
    else { return nil }

    let order = profile["profiles_order"] as? [String] ?? cache.keys.sorted()
    profiles = order.compactMap { id in
      cache[id].map { ChromeProfile(id: id, name: Self.name(of: $0), directory: root.appending(path: id)) }
    }
    lastUsed = profile["last_used"] as? String
  }

  private static func name(of info: [String: Any]) -> String {
    let profileName = info["name"] as? String ?? "Chrome"
    guard info["is_using_default_name"] as? Bool == true,
      let accountName = info["gaia_name"] as? String, !accountName.isEmpty
    else { return profileName }
    return accountName
  }
}
