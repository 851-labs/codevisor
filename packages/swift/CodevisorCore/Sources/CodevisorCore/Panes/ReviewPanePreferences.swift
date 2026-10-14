import CodevisorClient
import Foundation

public struct ReviewPanePreferences: Codable, Equatable, Sendable {
  public var mode: ServerGitDiffMode
  public var base: String?
  public var viewed: [String: String]

  public init(mode: ServerGitDiffMode = .branch, base: String? = nil, viewed: [String: String] = [:]) {
    self.mode = mode
    self.base = base
    self.viewed = viewed
  }

  public func isViewed(path: String, fingerprint: String?) -> Bool {
    guard let fingerprint else { return false }
    return viewed[path] == fingerprint
  }

  public mutating func setViewed(
    _ isViewed: Bool, path: String, fingerprint: String?, current: Set<String>
  ) {
    viewed = viewed.filter { current.contains($0.key) }
    if isViewed, let fingerprint {
      viewed[path] = fingerprint
    } else {
      viewed[path] = nil
    }
  }

  public func comparesSame(as other: ReviewPanePreferences) -> Bool {
    mode == other.mode && base == other.base
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawMode = try container.decodeIfPresent(String.self, forKey: .mode)
    mode = rawMode.flatMap(ServerGitDiffMode.init(rawValue:)) ?? .branch
    base = try container.decodeIfPresent(String.self, forKey: .base)
    viewed = try container.decodeIfPresent([String: String].self, forKey: .viewed) ?? [:]
  }
}
